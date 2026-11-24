# CLAY

[English](https://github.com/henwanla/CLAY/blob/main/README.en.md) · [更新记录](https://github.com/henwanla/CLAY/blob/main/CHANGELOG.md) · [GitHub Releases](https://github.com/henwanla/CLAY/releases)

CLAY 是原生 macOS 代理客户端。它把 VMess/VLESS 节点、订阅、菜单栏、PAC 分流和实时连接仪表放在同一个应用里。0.3.0 是预览版；公开安装包仅支持 Apple Silicon，最低构建目标为 macOS 13。

## 安装与开始使用

1. **本机预览包**：打开 `CLAY.app`，它会查找同级目录的 `Dependencies/mihomo`。将 App 单独移到其他目录后，可以在「设置」重新选择内核。
2. **GitHub 安装包**：下载 `CLAY-0.3.0-macos-arm64.zip` 和同名的 `.zip.sha256`。在下载目录执行 `shasum -a 256 -c CLAY-0.3.0-macos-arm64.zip.sha256`，校验通过后解压。公开包没有附带 Mihomo，请按下文安装并在「设置 → 选择 Mihomo…」中选中它。App 使用临时签名，未经过 Developer ID 签名和公证；如果系统禁止打开，可从源码构建，并遵守本机安全策略。
3. 在「订阅」点「添加订阅…」，粘贴服务商提供的 HTTPS 地址；也可以从「节点」粘贴分享链接，或导入 UTF-8 的 JSON、YAML 和文本文件。
4. 选择节点并点「启动」。「概览」显示本机代理地址，手动填写时 HTTP 和 SOCKS5 共用这个端口。需要按规则分流时，使用「PAC 规则」。
5. 关闭窗口后代理继续运行。macOS 菜单栏可查看状态、复制地址、重新打开窗口或启停代理。「退出 CLAY」或 `⌘Q` 会结束会话；应用不会在登录 macOS 后自动启动。

### 为公开安装包准备 Mihomo

从 [Mihomo v1.19.34 官方发布](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34) 的 Assets 下载 `mihomo-darwin-arm64-v1.19.34.gz`。在下载目录校验压缩文件，再解压到用户目录：

```sh
shasum -a 256 mihomo-darwin-arm64-v1.19.34.gz
# 预期：1a7a20eca63fbbaec90137717465bfde488d0db2a3a79b8fadebf9b2545b6e4c
mkdir -p "$HOME/.local/bin"
gzip -dc mihomo-darwin-arm64-v1.19.34.gz > "$HOME/.local/bin/mihomo-v1.19.34"
shasum -a 256 "$HOME/.local/bin/mihomo-v1.19.34"
# 预期：a55a9073f9b7b1fa596a82c034d2dae3407ec34732102b6e42c5513ce3033f34
chmod 755 "$HOME/.local/bin/mihomo-v1.19.34"
```

任一步的摘要不一致就停止。选文件时可按 `⌘⇧G` 输入 `~/.local/bin`，再选 `mihomo-v1.19.34`。也可以选择已信任的其他 Mihomo 可执行文件，兼容性以 v1.19.34 的验证为基准。

## PAC 分流

| 模式 | 怎么用 | 影响范围 |
| --- | --- | --- |
| 独立代理 | 启动 CLAY 后，在需要的应用里手动填写 HTTP/SOCKS5 地址。 | 仅使用该地址的应用；不修改 macOS 网络设置。 |
| 本机 PAC | 「PAC 规则 → 启动本机 PAC」，复制回环地址到支持 PAC 的应用。 | 仅使用该 PAC 地址的应用；不修改 macOS 网络设置。 |
| 系统 PAC | 在「PAC 规则」选择网络服务，点「应用到 macOS」。 | 修改所选网络服务的代理设置。启用期间暂时关闭该服务的手动 HTTP、HTTPS、SOCKS 代理和自动代理发现。 |

规则从上到下，命中第一条后停止；未命中时由你选择直连或代理，初始设置为代理。支持完整域名/IP、域名后缀、域名关键词、IPv4 网段；IP 网段只匹配明确写出的 IPv4 地址，不触发 DNS 查询。回环地址始终直连；开启「本地和私有地址直连」后，显式规则仍可覆盖这一默认行为。可输入域名、IP 或 URL 预览命中结果。批量导入采用以下格式，每行一条，追加到列表末尾：

```text
DOMAIN,docs.example.com,DIRECT
DOMAIN-SUFFIX,example.com,PROXY
IP-CIDR,10.0.0.0/8,DIRECT
```

规则编辑后会在本机保存；已在使用的 PAC 需点「更新」才生效。本机 PAC 更新后为新地址，请重新复制到手动配置的应用。应用到 macOS 前，CLAY 会保存所选网络服务的原代理设置。停用系统 PAC 可点「恢复原系统设置」；正常停止或退出时 CLAY 也会尝试恢复。应用或恢复时 macOS 可能要求管理员授权。只有遵循 macOS 代理设置的应用才会使用系统 PAC。如恢复失败，应用会提示处理；强制退出后重开 CLAY，从「PAC 规则」或菜单栏点「恢复原网络代理设置」。如果其他工具已经接管设置，CLAY 会保留对方的设置。切换 Wi‑Fi 或以太网服务后，如需给新服务启用 PAC，请先恢复原服务，再选新服务应用。

## 仪表、订阅与诊断

- **概览**显示实时上传和下载速度、短时曲线、本次会话累计量和活动连接数。**连接**可按目标、命中规则或代理链搜索，按时间或流量排序，并关闭单条或全部连接。连接信息只用于当前会话显示；PAC 直连流量不经过内核，因此不会计入。
- **订阅**可以保存多份，手动刷新、切换使用或移除。刷新失败保留上次成功的缓存；运行中变更订阅后，当前会话使用原列表，重新启动代理时应用新列表。网址和原始订阅缓存在本机 `~/Library/Application Support/CLAY/Subscriptions/`，包含凭据，请勿分享这个目录。手动导入只保留到本次应用退出。
- **诊断**可探测当前或全部节点，比较两次批量测试，复制不含节点名、服务商地址、UUID、订阅链接和原始配置的诊断报告。探测会通过节点请求 gstatic.com 的 204 地址。

**兼容范围**：VMess/VLESS 分享链接、Base64 链接列表、V2Ray/Xray JSON 出站及 Clash/Mihomo YAML 或 JSON 的内联 `proxies`。下载上限 2 MiB，每份最多导入 100 个兼容节点；本机回环夹具允许 HTTP。支持 TCP/RAW、WebSocket、gRPC，及常见 TLS、SNI 和 VLESS REALITY/Vision。导入只读取兼容节点；Clash 的 `proxy-providers`、策略组、规则、DNS、TUN、入站和原配置不会执行。CLAY 的 PAC 是独立规则；不提供 TUN、完整 Clash 配置执行、XHTTP 或复杂链式代理。

## 源码与验证

```sh
bash scripts/swift-local.sh build -c release
.build/release/CLAYCoreChecks
python3 scripts/smoke-subscriptions.py .build/release/CLAYCoreChecks
```

[参与开发](https://github.com/henwanla/CLAY/blob/main/CONTRIBUTING.md) · [架构调研](https://github.com/henwanla/CLAY/blob/main/docs/架构调研.md) · [产品与付费验证](https://github.com/henwanla/CLAY/blob/main/docs/产品与付费验证.md) · [验收记录](https://github.com/henwanla/CLAY/blob/main/docs/验收记录.md) · [打包及发布](https://github.com/henwanla/CLAY/blob/main/docs/RELEASING.md)

CLAY 原创代码以 [MIT](https://github.com/henwanla/CLAY/blob/main/LICENSE) 许可发布。Yams 和 libyaml 各有 [上游许可证](https://github.com/henwanla/CLAY/blob/main/Vendor/Yams/UPSTREAM.md)。Mihomo 是按其 GPL 许可发布的独立依赖；本机预览包附有其许可证和固定版本的源码入口，公开 ZIP 不含该内核。
