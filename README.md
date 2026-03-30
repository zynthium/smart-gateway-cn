# Smart Gateway CN

基于 Sing-box 的多订阅地区优先级透明代理管理工具。

该项目提供了一个强大的 Bash 脚本，用于在 Linux 系统上一键部署和管理基于 Sing-box 的透明代理。它支持多订阅链接解析、智能地区优选、PAC 域名分流以及内置的 Web Dashboard 监控面板。

## 功能特性

- **多订阅整合**：支持配置多个订阅链接，自动拉取、去重并缓存节点数据。
- **智能地区优先级**：支持通过环境变量自定义地区分组与正则匹配逻辑（默认优先级：新加坡 > 美国 > 日本 > 香港），优先使用低延迟高优先级的地区节点。
- **高可用容灾**：利用 UrlTest 与自动测速容差控制，实现节点组内的自动故障转移。
- **自动化分流**：集成 GFWList PAC 规则与 GeoIP/Geosite，实现国内流量直连，国外流量自动代理的透明路由。
- **可视化控制面板**：开启 Clash API 兼容的外部控制器，可直接通过浏览器访问 Web Dashboard 查看实时延迟与切换节点。
- **自动化运维**：支持一键更新内核、自动生成 Systemd 服务，并可开启 Cron 定时任务实现节点的每周自动更新。

## 环境要求

- Linux 操作系统 (支持 Debian/Ubuntu 或 CentOS/RHEL 系列)
- `root` 或 `sudo` 权限
- 确保系统已安装 `curl`, `wget`, `jq` (脚本会自动尝试安装缺失依赖)

## 快速开始

下载脚本并赋予执行权限，然后以 root 身份运行：

```bash
# 下载管理脚本
wget https://raw.githubusercontent.com/zynthium/smart-gateway-cn/main/sb_manager.sh

# 赋予执行权限
chmod +x sb_manager.sh

# 运行交互式控制面板
sudo ./sb_manager.sh
```

首次运行脚本时，会自动进入配置向导，你需要输入：
1. 你的节点订阅链接（多个链接使用逗号 `,` 分隔）
2. Web 面板的 API 端口（默认 `9090`）
3. Web 面板的访问密钥（默认 `singbox_admin`）

> [!TIP]
> 配置文件默认将保存在 `/etc/sing-box/.env`。

## 使用说明

直接运行 `./sb_manager.sh` 将打开交互式菜单，包含以下核心功能：

1. **极速安装 / 全量更新**：自动拉取最新 Sing-box 核心、更新节点配置并重启服务。
2. **修改配置**：随时更改订阅链接或面板密码。
3. **查看实时运行日志**：排查网络或节点故障。
4. **运行网络连通性测试**：检测国内外（Baidu/Google）连通性及当前真实出口 IP。
5. **查看节点列表与延迟状态**：查看当前激活的策略组和各节点的实时延迟。
6. **管理自动更新**：一键开启或关闭定时全量更新任务。
7. **彻底卸载**：清理内核及服务（可选择是否保留订阅配置）。

### 命令行快捷参数

你也可以通过附加参数来跳过菜单直接执行对应任务：

```bash
./sb_manager.sh update    # 全量更新 (拉取订阅、生成配置并重启)
./sb_manager.sh test      # 测速并检查当前出口IP
./sb_manager.sh nodes     # 查看当前节点列表及延迟
./sb_manager.sh config    # 重新进入配置向导
./sb_manager.sh uninstall # 卸载工具
```

## 环境变量注入 (高级)

为了方便在 Docker 容器或自动化 CI/CD 环境中使用，脚本支持通过全局环境变量直接注入配置，从而跳过交互式提示：

- `GLOBAL_SUB_URLS_STR`: 订阅链接字符串（多个链接用 `,` 分隔）
- `GLOBAL_API_PORT`: API 监听端口
- `GLOBAL_API_SECRET`: API 访问密钥
- `GLOBAL_PRIORITY_REGIONS_STR`: 地区优先级及正则匹配配置（格式：`分组名:正则1|正则2,分组名:正则1`）

### 完整环境变量配置示例

在 Linux 环境下，你可以直接导出这些环境变量后运行脚本，实现完全静默部署：

```bash
export GLOBAL_SUB_URLS_STR="https://sub.example.com/link1,https://sub.example.com/link2"
export GLOBAL_API_PORT="9090"
export GLOBAL_API_SECRET="my_secure_password"
# 优先级从左到右递减，可根据需求自定义地区和匹配正则
export GLOBAL_PRIORITY_REGIONS_STR="SG:新加坡|SG|Singapore,US:美国|US|United States,JP:日本|JP|Japan,HK:香港|HK|Hong Kong"

# 运行一键全量更新部署
sudo -E ./sb_manager.sh update
```

> [!TIP]
> 上述配置也会被自动持久化保存到 `/etc/sing-box/.env` 文件中，你可以随时编辑该文件来修改配置。

> [!IMPORTANT]
> 如果你在云服务器或带有防火墙的环境中使用，请务必在安全组/防火墙规则中放行对应的 API 端口（例如 `9090`），否则将无法在外部访问 Web Dashboard。
