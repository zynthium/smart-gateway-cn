#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GLOBAL_SUB_URLS_STR=""
GLOBAL_API_PORT=""
GLOBAL_API_SECRET=""
GLOBAL_PRIORITY_REGIONS_STR=""
SUB_URLS_STR=""
API_PORT=""
API_SECRET=""
PRIORITY_REGIONS_STR=""
SB_MANAGER_LIB_ONLY=1 source "$ROOT_DIR/sb_manager.sh" noop >/dev/null

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $message"
        echo "expected: $expected"
        echo "actual:   $actual"
        exit 1
    fi
}

assert_success() {
    local message="$1"
    shift

    if ! "$@"; then
        echo "FAIL: $message"
        exit 1
    fi
}

assert_failure() {
    local message="$1"
    shift

    if "$@"; then
        echo "FAIL: $message"
        exit 1
    fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

LOCAL_SUB="$TMP_DIR/local-sub.json"
cat > "$LOCAL_SUB" <<'JSON'
{
  "outbounds": [
    { "type": "vmess", "tag": "SG Test" }
  ]
}
JSON

assert_success "absolute local path should be detected" is_local_subscription_source "$LOCAL_SUB"
assert_success "file:// local path should be detected" is_local_subscription_source "file://$LOCAL_SUB"
assert_failure "https URL should stay remote" is_local_subscription_source "https://example.com/sub"

DATA="$(fetch_subscription_data "$LOCAL_SUB" "$TMP_DIR/cache.json" 1 2>/dev/null)"
assert_equals "SG Test" "$(echo "$DATA" | jq -r '.outbounds[0].tag')" "local JSON should be read unchanged"

DATA_FILE_SCHEME="$(fetch_subscription_data "file://$LOCAL_SUB" "$TMP_DIR/cache.json" 1 2>/dev/null)"
assert_equals "SG Test" "$(echo "$DATA_FILE_SCHEME" | jq -r '.outbounds[0].tag')" "file:// JSON should be read unchanged"

LOCAL_CLASH_YAML="$TMP_DIR/local-clash.yml"
cat > "$LOCAL_CLASH_YAML" <<'YAML'
proxies:
  - name: "SG YAML SS"
    type: ss
    server: sg.example.com
    port: 8388
    cipher: aes-128-gcm
    password: ss-password
  - name: "US YAML VMess"
    type: vmess
    server: us.example.com
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    alterId: 0
    cipher: auto
    tls: true
    servername: us.example.com
    network: ws
    ws-opts:
      path: /ws
      headers:
        Host: edge.example.com
YAML

if ! YAML_DATA="$(fetch_subscription_data "$LOCAL_CLASH_YAML" "$TMP_DIR/cache.json" 1 2>/dev/null)"; then
    echo "FAIL: local Clash YAML should be accepted"
    exit 1
fi
assert_equals "2" "$(echo "$YAML_DATA" | jq '.outbounds | length')" "local Clash YAML should convert proxies to outbounds"
assert_equals "shadowsocks" "$(echo "$YAML_DATA" | jq -r '.outbounds[0].type')" "ss YAML proxy should become shadowsocks"
assert_equals "SG YAML SS" "$(echo "$YAML_DATA" | jq -r '.outbounds[0].tag')" "ss YAML proxy should keep name as tag"
assert_equals "8388" "$(echo "$YAML_DATA" | jq -r '.outbounds[0].server_port')" "ss YAML proxy should convert port"
assert_equals "vmess" "$(echo "$YAML_DATA" | jq -r '.outbounds[1].type')" "vmess YAML proxy should stay vmess"
assert_equals "true" "$(echo "$YAML_DATA" | jq -r '.outbounds[1].tls.enabled')" "vmess YAML tls should be enabled"
assert_equals "ws" "$(echo "$YAML_DATA" | jq -r '.outbounds[1].transport.type')" "vmess YAML ws network should become ws transport"
assert_equals "edge.example.com" "$(echo "$YAML_DATA" | jq -r '.outbounds[1].transport.headers.Host')" "vmess YAML ws host should convert"

MISSING="$TMP_DIR/missing.json"
if fetch_subscription_data "$MISSING" "$TMP_DIR/cache.json" 1 >/dev/null 2>&1; then
    echo "FAIL: missing explicit local file should fail"
    exit 1
fi
