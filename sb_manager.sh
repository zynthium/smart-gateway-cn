#!/bin/bash

# ==========================================
#         Sing-box 地区优先级透明代理
# ==========================================

# 配置文件路径
ENV_FILE="/etc/sing-box/.env"

# 默认配置（如果 .env 文件不存在或未设置对应值）
DEFAULT_SUB_URLS=()
DEFAULT_API_PORT="9090"
DEFAULT_API_SECRET="singbox_admin"
DEFAULT_PRIORITY_REGIONS=(
    "SG:新加坡|SG|Singapore"
    "US:美国|US|United States"
    "JP:日本|JP|Japan"
    "HK:香港|HK|Hong Kong"
)

# 加载配置
load_env() {
    # 1. 尝试从本地 .env 文件读取配置
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi

    # 2. 如果存在外部注入的全局环境变量，优先使用全局变量 (支持 Docker / 自动化部署场景)
    if [ -n "$GLOBAL_SUB_URLS_STR" ]; then
        SUB_URLS_STR="$GLOBAL_SUB_URLS_STR"
    fi
    if [ -n "$GLOBAL_API_PORT" ]; then
        API_PORT="$GLOBAL_API_PORT"
    fi
    if [ -n "$GLOBAL_API_SECRET" ]; then
        API_SECRET="$GLOBAL_API_SECRET"
    fi
    if [ -n "$GLOBAL_PRIORITY_REGIONS_STR" ]; then
        PRIORITY_REGIONS_STR="$GLOBAL_PRIORITY_REGIONS_STR"
    fi

    # 3. 解析订阅来源字符串
    if [ -n "$SUB_URLS_STR" ]; then
        IFS=',' read -r -a SUB_URLS <<< "$SUB_URLS_STR"
    else
        SUB_URLS=("${DEFAULT_SUB_URLS[@]}")
    fi

    # 解析优先级字符串
    if [ -n "$PRIORITY_REGIONS_STR" ]; then
        IFS=',' read -r -a PRIORITY_REGIONS <<< "$PRIORITY_REGIONS_STR"
    else
        PRIORITY_REGIONS=("${DEFAULT_PRIORITY_REGIONS[@]}")
    fi

    # 4. 设置默认回退值
    API_PORT="${API_PORT:-$DEFAULT_API_PORT}"
    API_SECRET="${API_SECRET:-$DEFAULT_API_SECRET}"
}

# 交互式配置并保存到 .env
setup_env() {
    echo -e "${BLUE}=== 首次运行/配置向导 ===${NC}"
    mkdir -p /etc/sing-box

    local current_urls=""
    if [ ${#SUB_URLS[@]} -gt 0 ]; then
        current_urls=$(IFS=','; echo "${SUB_URLS[*]}")
    fi

    read -p "请输入订阅地址或本地订阅文件 (多个请用逗号 ',' 分隔) [${current_urls}]: " input_urls
    if [ -n "$input_urls" ]; then
        SUB_URLS_STR="$input_urls"
    else
        SUB_URLS_STR="$current_urls"
    fi

    read -p "请输入 API 端口 [${API_PORT:-$DEFAULT_API_PORT}]: " input_port
    API_PORT="${input_port:-${API_PORT:-$DEFAULT_API_PORT}}"

    read -p "请输入 Dashboard 访问密钥 [${API_SECRET:-$DEFAULT_API_SECRET}]: " input_secret
    API_SECRET="${input_secret:-${API_SECRET:-$DEFAULT_API_SECRET}}"

    local current_regions=""
    if [ ${#PRIORITY_REGIONS[@]} -gt 0 ]; then
        current_regions=$(IFS=','; echo "${PRIORITY_REGIONS[*]}")
    fi
    read -p "请输入地区优先级配置 (多个用逗号 ',' 分隔) [${current_regions}]: " input_regions
    if [ -n "$input_regions" ]; then
        PRIORITY_REGIONS_STR="$input_regions"
    else
        PRIORITY_REGIONS_STR="$current_regions"
    fi

    # 写入 .env 文件
    cat <<EOF > "$ENV_FILE"
# Sing-box Manager Environment Variables
SUB_URLS_STR="$SUB_URLS_STR"
API_PORT="$API_PORT"
API_SECRET="$API_SECRET"
PRIORITY_REGIONS_STR="$PRIORITY_REGIONS_STR"
EOF
    echo -e "${GREEN}配置已保存至 $ENV_FILE${NC}\n"

    # 重新加载配置
    load_env

    # 提示用户是否立即应用配置
    read -p "是否立即应用新配置？(将重新拉取订阅并重启服务) [Y/n]: " apply
    if [[ "$apply" != "n" && "$apply" != "N" ]]; then
        do_update
    else
        echo -e "${YELLOW}配置已保存但尚未生效。请稍后运行选项 1 (全量更新) 以应用新配置。${NC}"
    fi
}

# 订阅与防封锁配置
CACHE_DIR="/etc/sing-box/cache"
CACHE_EXPIRE=$((24 * 3600)) # 缓存过期时间 (秒)，默认 24 小时
UA_SPOOF="clash-verge/v2.4.7" # 伪装的 User-Agent

PAC_URL="https://cdn.jsdelivr.net/gh/petronny/gfwlist2pac@master/gfwlist.pac"
INSTALL_PATH="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
GH_PROXY="https://ghproxy.net/"
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

is_local_subscription_source() {
    local source="$1"

    case "$source" in
        http://*|https://*)
            return 1
            ;;
        file://*|/*|./*|../*)
            return 0
            ;;
    esac

    [ -f "$source" ]
}

normalize_local_subscription_path() {
    local source="$1"

    if [[ "$source" == file://* ]]; then
        source="${source#file://}"
    fi

    printf '%s\n' "$source"
}

is_yaml_subscription_file() {
    local file_path="$1"

    case "$file_path" in
        *.yml|*.yaml|*.YML|*.YAML)
            return 0
            ;;
    esac

    return 1
}

convert_clash_yaml_subscription() {
    local file_path="$1"

    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}错误: 解析 YAML 订阅需要 python3，请先安装 python3。${NC}" >&2
        return 1
    fi

    python3 - "$file_path" <<'PY'
import json
import re
import sys


def strip_comment(line):
    quote = None
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
            continue
        if char == "#" and (index == 0 or line[index - 1].isspace()):
            return line[:index]
    return line


def split_top_level(value, delimiter=","):
    parts = []
    current = []
    quote = None
    depth = 0
    escaped = False

    for char in value:
        if escaped:
            current.append(char)
            escaped = False
            continue
        if char == "\\":
            current.append(char)
            escaped = True
            continue
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            current.append(char)
            quote = char
            continue
        if char in "[{(":
            depth += 1
        elif char in "]})" and depth > 0:
            depth -= 1
        if char == delimiter and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(char)

    parts.append("".join(current).strip())
    return parts


def split_key_value(text):
    quote = None
    escaped = False
    for index, char in enumerate(text):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
            continue
        if char == ":":
            return text[:index].strip(), text[index + 1 :].strip()
    return None, None


def parse_scalar(value):
    value = value.strip()
    if value == "":
        return ""

    low = value.lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("null", "none", "~"):
        return None

    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        return value[1:-1]

    if value.startswith("[") and value.endswith("]"):
        body = value[1:-1].strip()
        if not body:
            return []
        return [parse_scalar(part) for part in split_top_level(body)]

    if value.startswith("{") and value.endswith("}"):
        body = value[1:-1].strip()
        result = {}
        if not body:
            return result
        for part in split_top_level(body):
            key, val = split_key_value(part)
            if key is not None:
                result[parse_scalar(key)] = parse_scalar(val)
        return result

    if re.fullmatch(r"-?\d+", value):
        try:
            return int(value)
        except ValueError:
            pass

    return value


def read_proxies(path):
    with open(path, "r", encoding="utf-8") as handle:
        raw_lines = handle.readlines()

    proxies_start = None
    proxies_indent = 0
    for index, raw in enumerate(raw_lines):
        line = strip_comment(raw.rstrip("\n")).rstrip()
        if not line.strip() or line.strip() in ("---", "..."):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if line.strip() == "proxies:":
            proxies_start = index + 1
            proxies_indent = indent
            break

    if proxies_start is None:
        raise ValueError("missing top-level proxies")

    proxies = []
    current = None
    proxy_item_indent = None
    stack = []

    for raw in raw_lines[proxies_start:]:
        line = strip_comment(raw.rstrip("\n")).rstrip()
        if not line.strip() or line.strip() in ("---", "..."):
            continue

        indent = len(line) - len(line.lstrip(" "))
        text = line.strip()

        if indent <= proxies_indent and not text.startswith("- "):
            break

        if text.startswith("- ") and (
            current is None or proxy_item_indent is None or indent <= proxy_item_indent
        ):
            current = {}
            proxies.append(current)
            proxy_item_indent = indent
            stack = [(indent, current)]
            text = text[2:].strip()
            if not text:
                continue
            key, value = split_key_value(text)
            if key is None:
                continue
            current[key] = parse_scalar(value)
            continue

        if current is None:
            continue

        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1] if stack else current

        key, value = split_key_value(text)
        if key is None:
            continue

        if value == "":
            child = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = parse_scalar(value)

    return proxies


def lower(value):
    return str(value or "").lower()


def first(proxy, *keys):
    for key in keys:
        value = proxy.get(key)
        if value not in (None, ""):
            return value
    return None


def bool_value(value):
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).lower() in ("true", "1", "yes", "on")


def add_tls(outbound, proxy, default_enabled=False):
    enabled = default_enabled
    if "tls" in proxy:
        enabled = bool_value(proxy.get("tls"))
    if proxy.get("reality-opts"):
        enabled = True

    if not enabled:
        return

    tls = {"enabled": True}
    server_name = first(proxy, "servername", "sni", "serverName")
    if server_name:
        tls["server_name"] = server_name
    if "skip-cert-verify" in proxy:
        tls["insecure"] = bool_value(proxy.get("skip-cert-verify"))

    fingerprint = proxy.get("client-fingerprint")
    if fingerprint:
        tls["utls"] = {"enabled": True, "fingerprint": fingerprint}

    reality_opts = proxy.get("reality-opts")
    if isinstance(reality_opts, dict):
        reality = {"enabled": True}
        public_key = first(reality_opts, "public-key", "publicKey")
        short_id = first(reality_opts, "short-id", "shortId")
        if public_key:
            reality["public_key"] = public_key
        if short_id:
            reality["short_id"] = short_id
        tls["reality"] = reality

    outbound["tls"] = tls


def add_transport(outbound, proxy):
    network = lower(proxy.get("network"))
    if network in ("", "tcp"):
        return

    if network == "ws":
        opts = proxy.get("ws-opts") if isinstance(proxy.get("ws-opts"), dict) else {}
        transport = {"type": "ws"}
        path = opts.get("path") or proxy.get("ws-path")
        if path:
            transport["path"] = path
        headers = opts.get("headers") if isinstance(opts.get("headers"), dict) else {}
        host = headers.get("Host") or headers.get("host") or proxy.get("ws-host")
        if host:
            transport["headers"] = {"Host": host}
        outbound["transport"] = transport
        return

    if network == "grpc":
        opts = proxy.get("grpc-opts") if isinstance(proxy.get("grpc-opts"), dict) else {}
        service_name = first(opts, "grpc-service-name", "serviceName", "service-name")
        transport = {"type": "grpc"}
        if service_name:
            transport["service_name"] = service_name
        outbound["transport"] = transport
        return

    if network in ("h2", "http"):
        opts = proxy.get("h2-opts") if isinstance(proxy.get("h2-opts"), dict) else {}
        transport = {"type": "http"}
        path = opts.get("path")
        if path:
            transport["path"] = path
        host = opts.get("host")
        if host:
            transport["host"] = host if isinstance(host, list) else [host]
        outbound["transport"] = transport


def base_outbound(proxy, outbound_type):
    name = proxy.get("name")
    server = proxy.get("server")
    port = proxy.get("port")
    if not name or not server or port in (None, ""):
        raise ValueError("missing name/server/port")
    return {
        "type": outbound_type,
        "tag": str(name),
        "server": str(server),
        "server_port": int(port),
    }


def convert_proxy(proxy):
    proxy_type = lower(proxy.get("type"))

    if proxy_type in ("ss", "shadowsocks"):
        outbound = base_outbound(proxy, "shadowsocks")
        outbound["method"] = first(proxy, "cipher", "method")
        outbound["password"] = proxy.get("password")
        return outbound

    if proxy_type == "vmess":
        outbound = base_outbound(proxy, "vmess")
        outbound["uuid"] = proxy.get("uuid")
        security = proxy.get("cipher")
        if security:
            outbound["security"] = security
        alter_id = first(proxy, "alterId", "alter-id")
        if alter_id is not None:
            outbound["alter_id"] = int(alter_id)
        add_tls(outbound, proxy)
        add_transport(outbound, proxy)
        return outbound

    if proxy_type == "vless":
        outbound = base_outbound(proxy, "vless")
        outbound["uuid"] = proxy.get("uuid")
        flow = proxy.get("flow")
        if flow:
            outbound["flow"] = flow
        add_tls(outbound, proxy)
        add_transport(outbound, proxy)
        return outbound

    if proxy_type == "trojan":
        outbound = base_outbound(proxy, "trojan")
        outbound["password"] = proxy.get("password")
        add_tls(outbound, proxy, default_enabled=True)
        add_transport(outbound, proxy)
        return outbound

    if proxy_type in ("hysteria2", "hy2"):
        outbound = base_outbound(proxy, "hysteria2")
        outbound["password"] = proxy.get("password")
        add_tls(outbound, proxy, default_enabled=True)
        return outbound

    if proxy_type == "tuic":
        outbound = base_outbound(proxy, "tuic")
        outbound["uuid"] = proxy.get("uuid")
        outbound["password"] = proxy.get("password")
        add_tls(outbound, proxy, default_enabled=True)
        return outbound

    if proxy_type in ("socks5", "socks"):
        outbound = base_outbound(proxy, "socks")
        username = first(proxy, "username", "user")
        password = proxy.get("password")
        if username:
            outbound["username"] = username
        if password:
            outbound["password"] = password
        return outbound

    if proxy_type == "http":
        outbound = base_outbound(proxy, "http")
        username = first(proxy, "username", "user")
        password = proxy.get("password")
        if username:
            outbound["username"] = username
        if password:
            outbound["password"] = password
        add_tls(outbound, proxy)
        return outbound

    raise ValueError(f"unsupported proxy type: {proxy_type}")


def main():
    path = sys.argv[1]
    proxies = read_proxies(path)
    outbounds = []

    for proxy in proxies:
        try:
            outbound = convert_proxy(proxy)
        except Exception as exc:
            name = proxy.get("name", "<unknown>") if isinstance(proxy, dict) else "<unknown>"
            print(f"警告: 跳过不支持的 YAML 节点 {name}: {exc}", file=sys.stderr)
            continue
        outbounds.append(outbound)

    if not outbounds:
        raise SystemExit("错误: YAML 订阅未解析到支持的 proxies 节点")

    print(json.dumps({"outbounds": outbounds}, ensure_ascii=False))


if __name__ == "__main__":
    main()
PY
}

load_local_subscription_data() {
    local source="$1"
    local sub_count="$2"
    local file_path
    local data

    file_path=$(normalize_local_subscription_path "$source")

    if [ ! -f "$file_path" ]; then
        echo -e "${RED}错误: 本地订阅文件不存在 - ${file_path}${NC}" >&2
        return 1
    fi

    if [ ! -r "$file_path" ]; then
        echo -e "${RED}错误: 本地订阅文件不可读 - ${file_path}${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}正在加载本地订阅 ${sub_count}: ${file_path}...${NC}" >&2

    if is_yaml_subscription_file "$file_path"; then
        convert_clash_yaml_subscription "$file_path"
        return
    fi

    data=$(cat "$file_path")

    if ! echo "$data" | jq -e . >/dev/null 2>&1; then
        echo -e "${RED}错误: 本地订阅文件不是有效 JSON - ${file_path}${NC}" >&2
        return 1
    fi

    printf '%s\n' "$data"
}

fetch_remote_subscription_data() {
    local url="$1"
    local cache_file="$2"
    local sub_count="$3"
    local data=""
    local use_cache=false

    if [ -f "$cache_file" ]; then
        local file_mtime
        local current_time
        local time_diff

        file_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file")
        current_time=$(date +%s)
        time_diff=$((current_time - file_mtime))

        if [ "$time_diff" -lt "$CACHE_EXPIRE" ]; then
            use_cache=true
            echo -e "${BLUE}正在加载订阅 ${sub_count} (使用本地缓存，距下次强制刷新还剩 $(((CACHE_EXPIRE - time_diff) / 3600)) 小时)...${NC}" >&2
            data=$(cat "$cache_file")
        fi
    fi

    if [ "$use_cache" = false ]; then
        local curl_exit

        echo -e "${BLUE}正在拉取订阅 ${sub_count}: ${url}...${NC}" >&2
        # 使用 -sS 静默且展示错误，增加超时时间，伪装 UA，将错误输出到临时文件
        data=$(curl -sS -L --connect-timeout 15 -m 30 -A "$UA_SPOOF" "https://api.v1.mk/sub?target=singbox&url=${url}" 2>/tmp/curl_err.tmp)
        curl_exit=$?

        if [ $curl_exit -ne 0 ]; then
            local err_msg

            err_msg=$(cat /tmp/curl_err.tmp | tr '\n' ' ')
            echo -e "${RED}错误: 订阅请求失败 [curl code: $curl_exit] - ${err_msg}${NC}" >&2

            if [ -f "$cache_file" ]; then
                echo -e "${YELLOW}警告: 请求失败，回退使用旧缓存数据。${NC}" >&2
                data=$(cat "$cache_file")
            else
                return 1
            fi
        elif ! echo "$data" | jq -e . >/dev/null 2>&1; then
            echo -e "${RED}错误: 请求成功但返回了非 JSON 数据 (可能节点失效或被拦截) - ${url}${NC}" >&2
            echo -e "${RED}返回内容预览: $(echo "$data" | head -n 3 | cut -c 1-150)${NC}" >&2

            if [ -f "$cache_file" ]; then
                echo -e "${YELLOW}警告: 数据无效，回退使用旧缓存数据。${NC}" >&2
                data=$(cat "$cache_file")
            else
                return 1
            fi
        else
            printf '%s\n' "$data" > "$cache_file"
        fi
    fi

    printf '%s\n' "$data"
}

fetch_subscription_data() {
    local source="$1"
    local cache_file="$2"
    local sub_count="$3"

    if is_local_subscription_source "$source"; then
        load_local_subscription_data "$source" "$sub_count"
        return
    fi

    fetch_remote_subscription_data "$source" "$cache_file" "$sub_count"
}

format_utc_offset() {
    local offset_seconds="$1"
    if [[ -z "$offset_seconds" || "$offset_seconds" == "-" || "$offset_seconds" == "null" ]]; then
        echo "-"
        return
    fi

    if [[ "$offset_seconds" =~ ^-?[0-9]+$ ]]; then
        local sign="+"
        if (( offset_seconds < 0 )); then
            sign="-"
            offset_seconds=$(( -offset_seconds ))
        fi
        local hours=$(( offset_seconds / 3600 ))
        local minutes=$(( (offset_seconds % 3600) / 60 ))
        printf "%s%02d:%02d" "$sign" "$hours" "$minutes"
        return
    fi

    echo "$offset_seconds"
}

print_exit_ip_info() {
    local name="$1"
    local header="$2"
    local proxy="$3"
    local hint="$4"
    local msg_extra="$5"

    echo -e "${GREEN}${header}${NC}"

    local ip_info=""
    if [ -n "$proxy" ]; then
        ip_info=$(curl -s -x "$proxy" --connect-timeout 5 --max-time 8 "${IP_API_URL}")
    else
        ip_info=$(curl -s --connect-timeout 5 --max-time 8 "${IP_API_URL}")
    fi

    if [ -n "$ip_info" ] && echo "$ip_info" | jq -e '.status == "success"' >/dev/null 2>&1; then
        local ip country region region_code city district zip isp org asn tz offset_raw lat lon mobile proxy_flag hosting
        IFS=$'\x1f' read -r ip country region region_code city district zip isp org asn tz offset_raw lat lon mobile proxy_flag hosting < <(
            echo "$ip_info" | jq -r '[
              (.query // "-"),
              (.country // "-"),
              (.regionName // "-"),
              (.region // "-"),
              (.city // "-"),
              (.district // "-"),
              (.zip // "-"),
              (.isp // "-"),
              (.org // "-"),
              (.as // "-"),
              (.timezone // "-"),
              (.offset // "-"),
              (.lat // "-"),
              (.lon // "-"),
              (.mobile // false),
              (.proxy // false),
              (.hosting // false)
            ] | join("\u001f")'
        )

        local offset
        offset=$(format_utc_offset "$offset_raw")

        echo -e "IP \t : ${ip}"
        echo -e "地址 \t : ${country} ${region}(${region_code}) ${city} ${district}"
        echo -e "邮编 \t : ${zip}"
        echo -e "经纬度 \t : ${lat}, ${lon}"
        echo -e "运营商 \t : ${isp}"
        echo -e "组织 \t : ${org}"
        echo -e "ASN \t : ${asn}"
        echo -e "时区 \t : ${tz} (UTC${offset})"
        echo -e "属性 \t : mobile=${mobile}, proxy=${proxy_flag}, hosting=${hosting}"
    else
        local err
        err=$(echo "$ip_info" | jq -r '.message // empty' 2>/dev/null)
        if [ -n "$err" ]; then
            echo -e "${RED}获取${name} IP 失败: ${err}${msg_extra}${NC}"
        else
            echo -e "${RED}获取${name} IP 失败，请检查${hint}${NC}"
        fi
    fi
    echo ""
}

do_update() {
    # 加载配置
    load_env

    if [ ${#SUB_URLS[@]} -eq 0 ]; then
        echo -e "${RED}未配置订阅地址或本地订阅文件！请先运行 $0 config${NC}"
        return 1
    fi

    echo -e "${BLUE}[1/5] 环境检查与依赖安装...${NC}"
    apt-get update -y && apt-get install jq curl wget gawk grep python3 -y || yum install jq curl wget gawk grep python3 -y

    echo -e "${BLUE}[2/5] 更新 Sing-box 内核...${NC}"
    VERSION=$(curl -sL ${GH_PROXY}https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name 2>/dev/null || echo "v1.8.10")
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    wget -qO- "${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${ARCH}.tar.gz" | tar xz -C /tmp
    mv /tmp/sing-box*/sing-box $INSTALL_PATH && chmod +x $INSTALL_PATH && rm -rf /tmp/sing-box*

    echo -e "${BLUE}[3/5] 拉取订阅并按地区分组 (去重)...${NC}"
    # 1. 提取 PAC
    PAC_DOMAINS=$(curl -sL "$PAC_URL" | awk -F'"' '/"/{for(i=1;i<=NF;i++) if($i ~ /\./ && $i !~ / /) print $i}' | grep -vE 'http|\/|\*|\[|\]' | sort -u | jq -R . | jq -s .)

    # 2. 拉取所有节点并去重，按订阅顺序打上来源标记
    RAW_NODES="[]"
    SUB_COUNT=0

    # 确保缓存目录存在
    mkdir -p "$CACHE_DIR"

    for URL in "${SUB_URLS[@]}"; do
        SUB_COUNT=$((SUB_COUNT + 1))
        # 生成基于订阅来源的唯一缓存文件名
        URL_HASH=$(printf '%s' "$URL" | md5sum | awk '{print $1}')
        CACHE_FILE="${CACHE_DIR}/sub_${URL_HASH}.json"

        if ! DATA=$(fetch_subscription_data "$URL" "$CACHE_FILE" "$SUB_COUNT"); then
            continue
        fi

        # 过滤掉不需要的类型以及 sing-box 不支持的实验性类型（如 anytls），并为每个节点的 tag 加上前缀以区分来源，比如 "[Sub1] 原节点名"
        NODES=$(echo "$DATA" | jq -c --arg prefix "[Sub${SUB_COUNT}] " '.outbounds // [] | map(select(.type != "dns" and .type != "selector" and .type != "urltest" and .type != "direct" and .type != "block" and .type != "anytls")) | map(.tag = $prefix + .tag)')
        if [ -z "$NODES" ] || [ "$NODES" == "null" ]; then NODES="[]"; fi

        RAW_NODES=$(echo "$RAW_NODES" | jq -c --argjson n "$NODES" '. + $n | unique_by(.tag)')
    done

    # 3. 构建地区分组 Outbounds
    REGION_OUTBOUNDS="[]"
    TOP_LEVEL_TAGS="[]"

    for REGION_DATA in "${PRIORITY_REGIONS[@]}"; do
        R_NAME="${REGION_DATA%%:*}"
        R_REGEX="${REGION_DATA#*:}"

        # 筛选该地区节点
        R_NODES=$(echo "$RAW_NODES" | jq -c --arg reg "$R_REGEX" 'map(select(.tag | test($reg; "i")))')
        if [ -z "$R_NODES" ] || [ "$R_NODES" == "null" ]; then R_NODES="[]"; fi

        # 获取该地区节点总数
        R_TAGS_LEN=$(echo "$R_NODES" | jq length 2>/dev/null || echo 0)

        if [ "$R_TAGS_LEN" -gt 0 ]; then
            FALLBACK_TAG="${R_NAME}-Fallback-Group"
            SUB_GROUP_TAGS="[]"

            # 为每个订阅源单独创建一个 urltest 组
            for (( i=1; i<=$SUB_COUNT; i++ )); do
                SUB_PREFIX="\[Sub${i}\]"
                # 筛选属于当前订阅的当前地区节点
                SUB_R_NODES=$(echo "$R_NODES" | jq -c --arg prefix "^$SUB_PREFIX" 'map(select(.tag | test($prefix)))')
                SUB_R_TAGS=$(echo "$SUB_R_NODES" | jq -c 'map(.tag)')
                SUB_R_LEN=$(echo "$SUB_R_TAGS" | jq length 2>/dev/null || echo 0)

                if [ "$SUB_R_LEN" -gt 0 ]; then
                    SUB_GROUP_TAG="${R_NAME}-Sub${i}-UrlTest"
                    # 创建子组 urltest（带容差控制）
                    SUB_GROUP_OBJ=$(jq -n --arg tag "$SUB_GROUP_TAG" --argjson subs "$SUB_R_TAGS" \
                        '{type: "urltest", tag: $tag, outbounds: $subs, url: "https://www.gstatic.com/generate_204", interval: "3m", tolerance: 50}')

                    REGION_OUTBOUNDS=$(echo "$REGION_OUTBOUNDS" | jq -c --argjson g "$SUB_GROUP_OBJ" '. + [$g]')
                    SUB_GROUP_TAGS=$(echo "$SUB_GROUP_TAGS" | jq -c --arg t "$SUB_GROUP_TAG" '. + [$t]')
                fi
            done

            # 如果成功创建了子组，则创建一个包裹它们的 urltest 组 (高容差) 模拟 fallback 行为
            if [ "$(echo "$SUB_GROUP_TAGS" | jq length)" -gt 0 ]; then
                # Sing-box 没有 fallback 类型，利用 urltest 配合极大的容差值 (9999ms) 实现订阅间的主备顺序切换
                FALLBACK_OBJ=$(jq -n --arg tag "$FALLBACK_TAG" --argjson subs "$SUB_GROUP_TAGS" \
                    '{type: "urltest", tag: $tag, outbounds: $subs, url: "https://www.gstatic.com/generate_204", interval: "3m", tolerance: 9999}')

                REGION_OUTBOUNDS=$(echo "$REGION_OUTBOUNDS" | jq -c --argjson g "$FALLBACK_OBJ" '. + [$g]')
                TOP_LEVEL_TAGS=$(echo "$TOP_LEVEL_TAGS" | jq -c --arg t "$FALLBACK_TAG" '. + [$t]')
                # 将该地区节点定义加入全局
                REGION_OUTBOUNDS=$(echo "$REGION_OUTBOUNDS" | jq -c --argjson ns "$R_NODES" '. + $ns')
            fi
        fi
    done

    if [ "$(echo "$TOP_LEVEL_TAGS" | jq length)" -eq 0 ]; then
        echo -e "${RED}错误: 未能获取到任何符合条件的地区节点，请检查订阅地址、本地订阅文件或网络连接！${NC}"
        return 1
    fi

    echo -e "${BLUE}[4/5] 生成优先级配置...${NC}"
    mkdir -p $CONFIG_DIR
    cat <<EOF > $CONFIG_DIR/config.json
{
  "dns": {
    "servers": [
      { "tag": "dns_proxy", "address": "https://8.8.8.8/dns-query", "detour": "Main-Priority" },
      { "tag": "dns_direct", "address": "223.5.5.5", "detour": "direct" }
    ],
    "rules": [
      { "geosite": ["cn"], "server": "dns_direct" },
      { "domain_suffix": $PAC_DOMAINS, "server": "dns_proxy" }
    ],
    "final": "dns_direct"
  },
  "inbounds": [
    { "type": "tun", "inet4_address": "172.19.0.1/30", "inet6_address": "fdfe:dcba:9876::1/126", "auto_route": true, "strict_route": false, "sniff": true },
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080 }
  ],
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:${API_PORT}",
      "secret": "${API_SECRET}",
      "external_ui": "dashboard",
      "external_ui_download_url": "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip",
      "external_ui_download_detour": "Main-Priority"
    }
  },
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "dns", "tag": "dns-out" },
    {
      "type": "urltest",
      "tag": "Main-Priority",
      "outbounds": $(echo "$TOP_LEVEL_TAGS" | jq -c '.'),
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 9999
    }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "inbound": ["mixed-in"], "outbound": "Main-Priority" },
      { "domain_suffix": $PAC_DOMAINS, "outbound": "Main-Priority" },
      { "geoip": ["cn", "private"], "outbound": "direct" },
      { "geosite": ["cn"], "outbound": "direct" }
    ],
    "auto_detect_interface": true,
    "final": "Main-Priority"
  }
}
EOF
    # 合并所有节点和地区组到 outbounds
    jq --argjson groups "$REGION_OUTBOUNDS" '.outbounds += $groups' $CONFIG_DIR/config.json > /tmp/cfg.tmp && mv /tmp/cfg.tmp $CONFIG_DIR/config.json

    echo -e "${BLUE}[5/5] 重启 Sing-box 服务...${NC}"

    # 确保 systemd 服务文件存在
    if [ ! -f /etc/systemd/system/sing-box.service ]; then
        echo -e "${BLUE}创建 sing-box systemd 服务...${NC}"
        cat <<'EOF' > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
    fi

    systemctl restart sing-box
    echo -e "${GREEN}部署成功！${NC}"
    echo -e "地区优先级顺序: ${TOP_LEVEL_TAGS}"

    # 打印外部访问 Dashboard 的提示信息
    PUBLIC_IP=$(curl -s http://ifconfig.me 2>/dev/null)
    if [ -n "$PUBLIC_IP" ]; then
        echo -e "\n${BLUE}==============================================${NC}"
        echo -e "${GREEN}Web Dashboard 已开启！${NC}"
        echo -e "访问地址: http://${PUBLIC_IP}:${API_PORT}/ui"
        echo -e "访问密钥 (Secret): ${API_SECRET}"
        echo -e "提示: 如果无法访问，请确保你的服务器防火墙/安全组已放行 ${API_PORT} 端口"
        echo -e "${BLUE}==============================================${NC}\n"
    fi
}

setup_cron() {
    # 先获取脚本的绝对路径，确保定时任务能正确找到脚本
    SCRIPT_PATH=$(readlink -f "$0")
    
    (crontab -l 2>/dev/null | grep -v "sb_manager.sh"; echo "0 9 * * 1 $SCRIPT_PATH update >> /var/log/sb_update.log 2>&1") | crontab -
    echo -e "${GREEN}已开启自动更新 (每周一早上 9:00 执行全量更新)。${NC}"
    echo -e "日志将保存至: /var/log/sb_update.log"
}

manage_cron() {
    echo -e "${BLUE}=== 自动更新管理 ===${NC}"
    if crontab -l 2>/dev/null | grep -q "sb_manager.sh"; then
        echo -e "当前状态: ${GREEN}已开启${NC}"
        read -p "是否要关闭自动更新？[y/N]: " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            (crontab -l 2>/dev/null | grep -v "sb_manager.sh") | crontab -
            echo -e "${YELLOW}自动更新已关闭。${NC}"
        fi
    else
        echo -e "当前状态: ${YELLOW}未开启${NC}"
        read -p "是否要开启自动更新 (每周一早上9:00点执行)？[y/N]: " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            setup_cron
        fi
    fi
}

test_connectivity() {
    echo -e "${BLUE}=== 网络连通性测试 ===${NC}"

    echo -e "${BLUE}[1/2] 测试国内连通性 (Baidu)...${NC}"
    if curl -I -s --connect-timeout 5 https://www.baidu.com -w "HTTP_CODE: %{http_code}\n" | grep -q "200"; then
        echo -e "${GREEN}国内网络连通性: 正常 (Baidu)${NC}"
    else
        echo -e "${RED}国内网络连通性: 异常 (无法访问 Baidu)${NC}"
    fi

    echo -e "\n${BLUE}[2/2] 测试国外连通性 (Google)...${NC}"
    if curl -I -s --connect-timeout 5 https://www.google.com -w "HTTP_CODE: %{http_code}\n" | grep -E -q "200|301|302"; then
        echo -e "${GREEN}国外网络连通性: 正常 (Google)${NC}"
    else
        echo -e "${RED}国外网络连通性: 异常 (无法访问 Google，可能代理未生效或节点全部失效)${NC}"
    fi

    echo -e "\n${BLUE}=== 当前出口 IP 信息 ===${NC}"
    IP_API_URL="http://ip-api.com/json?lang=zh-CN"

    print_exit_ip_info "国内" "[国内出口 IP] (ip-api.com)" "" "网络连通性" ""
    print_exit_ip_info "国外" "[国外出口 IP] (ip-api.com, 经由代理)" "socks5h://127.0.0.1:2080" "代理连通性" "（请检查代理连通性）"
}

do_start() {
    echo -e "${BLUE}=== 开启代理 ===${NC}"

    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_DIR/config.json" ]; then
        echo -e "${RED}未找到配置文件 ($CONFIG_DIR/config.json)，请先运行选项 1 进行安装/全量更新。${NC}"
        return 1
    fi

    # 检查 sing-box 是否已安装
    if [ ! -f "$INSTALL_PATH" ]; then
        echo -e "${RED}未找到 Sing-box 程序 ($INSTALL_PATH)，请先运行选项 1 进行安装。${NC}"
        return 1
    fi

    # 检查服务是否已经在运行
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo -e "${YELLOW}Sing-box 服务已在运行中，无需重复开启。${NC}"
        return
    fi

    echo -e "${BLUE}正在启动 Sing-box 服务...${NC}"
    systemctl start sing-box 2>/dev/null

    # 等待片刻让服务完成启动
    sleep 1

    # 验证服务已启动
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo -e "${GREEN}代理已开启，网络流量将通过代理转发。${NC}"
    else
        echo -e "${RED}启动服务失败，请检查日志: journalctl -u sing-box -n 20${NC}"
    fi
}

do_stop() {
    echo -e "${BLUE}=== 关闭代理 ===${NC}"

    # 检查服务是否正在运行
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        echo -e "${YELLOW}Sing-box 服务当前未运行，无需关闭。${NC}"
        return
    fi

    echo -e "${BLUE}正在停止 Sing-box 服务...${NC}"
    systemctl stop sing-box 2>/dev/null

    # 验证服务已停止
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo -e "${RED}停止服务失败，请尝试手动执行: systemctl stop sing-box${NC}"
    else
        echo -e "${GREEN}代理已关闭，网络流量将不再经过代理。${NC}"
        echo -e "提示: 如需重新启动代理，请运行选项 7 (开启代理) 或执行: systemctl start sing-box"
    fi
}

do_uninstall() {
    echo -e "${RED}警告: 此操作将卸载 Sing-box 核心并清理相关定时任务。${NC}"
    read -p "确定要卸载吗？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${BLUE}已取消卸载。${NC}"
        return
    fi

    echo -e "${BLUE}停止并禁用服务...${NC}"
    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload

    echo -e "${BLUE}清理程序...${NC}"
    rm -f $INSTALL_PATH

    echo -e "${BLUE}清理定时任务...${NC}"
    (crontab -l 2>/dev/null | grep -v "sb_manager.sh") | crontab -

    echo -e "${YELLOW}是否要删除所有配置和缓存文件 (${CONFIG_DIR} 和 ${ENV_FILE})？${NC}"
    read -p "如果希望后续重装时保留节点配置，请选择否。删除配置？[y/N]: " rm_config
    if [[ "$rm_config" == "y" || "$rm_config" == "Y" ]]; then
        echo -e "${BLUE}清理配置文件...${NC}"
        rm -rf $CONFIG_DIR
        rm -f $ENV_FILE
        echo -e "${GREEN}配置文件已清理。${NC}"
    else
        echo -e "${BLUE}配置文件已保留。${NC}"
    fi

    echo -e "${GREEN}卸载完成！${NC}"
}

show_nodes() {
    echo -e "${BLUE}=== 当前代理节点列表及延迟 ===${NC}"

    AUTH_HEADER=""
    if [ -n "$API_SECRET" ]; then
        AUTH_HEADER="-H \"Authorization: Bearer ${API_SECRET}\""
    fi

    # 获取所有代理组状态信息
    PROXY_DATA=$(curl -s "http://127.0.0.1:${API_PORT}/proxies" -H "Authorization: Bearer ${API_SECRET}")

    # 检查是否成功获取数据
    if ! echo "$PROXY_DATA" | jq -e .proxies >/dev/null 2>&1; then
        echo -e "${RED}无法连接到 Sing-box API (127.0.0.1:${API_PORT}) 或鉴权失败。请确保代理服务正在运行且已包含 API 配置。${NC}"
        echo -e "提示: 如果您使用的是旧版本配置，请先运行选项 1 进行全量更新。\n"
        return
    fi

    # 提取顶层的 Main-Priority 当前正在使用的组 (处理 API 数据中 URL 编码的节点名)
    MAIN_NOW=$(echo "$PROXY_DATA" | jq -r '.proxies["Main-Priority"].now // empty')

    if [ -z "$MAIN_NOW" ]; then
        echo -e "${RED}未找到 'Main-Priority' 选择组或未选中任何节点。${NC}"
        echo -e "${RED}调试信息: 正在检查包含的组列表...${NC}"
        echo "$PROXY_DATA" | jq -r '.proxies | keys[]' | grep "Main" || echo "无 Main 组"
        echo ""
        return
    fi

    echo -e "当前地区策略组: ${GREEN}${MAIN_NOW}${NC}"

    # 如果 fallback 获取不到子组（可能是因为 Sing-box 刚启动还没有测速结果），则尝试直接取第一个
    ACTIVE_SUB_GROUP=$(echo "$PROXY_DATA" | jq -r --arg group "$MAIN_NOW" '.proxies[$group].now // empty')
    if [ -z "$ACTIVE_SUB_GROUP" ] || [ "$ACTIVE_SUB_GROUP" == "null" ]; then
        ACTIVE_SUB_GROUP=$(echo "$PROXY_DATA" | jq -r --arg group "$MAIN_NOW" '.proxies[$group].all[0] // empty')
    fi

    if [ -z "$ACTIVE_SUB_GROUP" ] || [ "$ACTIVE_SUB_GROUP" == "null" ]; then
        echo -e "${RED}无法获取当前活跃的子组。可能测速尚未完成。${NC}\n"
        return
    fi

    echo -e "当前使用订阅组: ${GREEN}${ACTIVE_SUB_GROUP}${NC}"

    # 提取当前激活的 urltest 子组中，实际正在使用的底层节点
    ACTUAL_NODE=$(echo "$PROXY_DATA" | jq -r --arg group "$ACTIVE_SUB_GROUP" '.proxies[$group].now // empty')
    if [ -z "$ACTUAL_NODE" ] || [ "$ACTUAL_NODE" == "null" ]; then
        ACTUAL_NODE=$(echo "$PROXY_DATA" | jq -r --arg group "$ACTIVE_SUB_GROUP" '.proxies[$group].all[0] // empty')
    fi
    echo -e "当前出站节点: ${GREEN}${ACTUAL_NODE}${NC}\n"

    echo -e "${BLUE}=== 节点详细信息 (${ACTIVE_SUB_GROUP}) ===${NC}"
    printf "%-5s | %-12s | %-s\n" "状态" "延迟" "节点名称 (唯一标志)"
    echo "--------------------------------------------------------"

    # 提取该 urltest 子组内的所有节点和延迟信息
    echo "$PROXY_DATA" | jq -r --arg group "$ACTIVE_SUB_GROUP" --arg actual "$ACTUAL_NODE" '
        .proxies[$group].all[] as $name |
        (if $name == $actual then "[*]  " else "[ ]  " end) as $prefix |
        (.proxies[$name].history | length) as $hlen |
        (.proxies[$name].history[-1].delay // 0) as $delay |
        if $hlen == 0 then
            $prefix + "| Untested   | " + $name
        elif $delay == 0 then
            $prefix + "| Timeout    | " + $name
        else
            $prefix + "| " + ($delay|tostring) + " ms       | " + $name
        end
    ' | while IFS= read -r line; do
        if [[ "$line" == "[*]"* ]]; then
            echo -e "${GREEN}${line}${NC}"
        elif [[ "$line" == *"Timeout/Error"* ]]; then
            echo -e "${RED}${line}${NC}"
        else
            echo -e "${line}"
        fi
    done
    echo ""
}

# 入口逻辑
if [ "${SB_MANAGER_LIB_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

load_env

# 如果未配置订阅来源且没有全局环境变量注入，或使用特定命令但无配置，强制进入配置向导
if [ ${#SUB_URLS[@]} -eq 0 ] && [[ "$1" == "update" || "$1" == "test" || -z "$1" ]]; then
    echo -e "${YELLOW}未检测到有效的配置信息，请先进行配置。${NC}"
    setup_env
fi

if [[ "$1" == "" || "$1" == "help" ]]; then
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "  Sing-box 多订阅透明代理管理面板  "
    echo -e "${BLUE}==============================================${NC}"
    echo -e "  1. 极速安装 / 全量更新 (含节点与 PAC 重载)"
    echo -e "  2. 修改配置 (订阅地址/文件、端口、密码等)"
    echo -e "  3. 查看实时运行日志 (排查故障用)"
    echo -e "  4. 运行网络连通性测试"
    echo -e "  5. 查看节点列表与延迟状态"
    echo -e "  6. 管理自动更新 (开启/关闭)"
    echo -e "  7. 开启代理 (启动 Sing-box 服务)"
    echo -e "  8. 关闭代理 (停止 Sing-box 服务)"
    echo -e "  9. 彻底卸载 (卸载核心，可选保留配置)"
    echo -e "  0. 退出脚本"
    echo -e "${BLUE}==============================================${NC}"
    read -p "请输入 [0-9]: " opt

    case $opt in
        1) do_update ;;
        2) setup_env ;;
        3) journalctl -u sing-box -f ;;
        4) test_connectivity ;;
        5) show_nodes ;;
        6) manage_cron ;;
        7) do_start ;;
        8) do_stop ;;
        9) do_uninstall ;;
        *) exit 0 ;;
    esac
else
    # 命令行参数模式
    case "$1" in
        update) do_update ;;
        test) test_connectivity ;;
        nodes) show_nodes ;;
        start) do_start ;;
        stop) do_stop ;;
        uninstall) do_uninstall ;;
        config) setup_env ;;
        *)
            echo -e "${BLUE}=== Sing-box 地区优先级自动分流部署工具 ===${NC}"
            echo -e "用法: $0 [选项]"
            echo -e "  (无参数)  - 进入交互式菜单"
            echo -e "  update    - 全量更新 (拉取订阅、生成配置并重启)"
            echo -e "  test      - 测速并检查当前出口IP"
            echo -e "  nodes     - 查看当前节点列表及延迟"
            echo -e "  start     - 开启代理 (启动 Sing-box 服务)"
            echo -e "  stop      - 关闭代理 (停止 Sing-box 服务)"
            echo -e "  config    - 修改配置"
            echo -e "  uninstall - 卸载工具 (可选是否清理配置)"
            echo -e "${BLUE}==============================================${NC}"
            ;;
    esac
fi
