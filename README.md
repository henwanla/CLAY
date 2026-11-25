# CLAY

[English](README.en.md) · [更新记录](CHANGELOG.md) · [GitHub Releases](https://github.com/henwanla/CLAY/releases)

CLAY 是原生 macOS 代理客户端，把节点、订阅、菜单栏、PAC 分流和实时连接仪表放在同一个应用里。已发布的 0.3.0 预览包面向 Apple Silicon（macOS 13 起）；本页也介绍 `develop` 上尚未发布的功能。

## 安装与开始使用

1. **本机预览包**：打开 `CLAY.app`，在「设置 → 选择 Mihomo…」选择同级目录的 `Dependencies/mihomo`。从新版源码构建时，CLAY 会记录首次确认的文件指纹；升级或替换内核后请校验来源并重新选择。
2. **GitHub 安装包**：下载 `CLAY-0.3.0-macos-arm64.zip` 和同名的 `.zip.sha256`。在下载目录执行 `shasum -a 256 -c CLAY-0.3.0-macos-arm64.zip.sha256`，校验通过后解压。公开包没有附带 Mihomo，请按下文安装并在「设置 → 选择 Mihomo…」中选中它。App 使用临时签名，未经过 Developer ID 签名和公证；如果系统禁止打开，可从源码构建，并遵守本机安全策略。
3. 在「订阅」点「添加订阅…」，粘贴服务商提供的 HTTPS 地址；也可以从「节点」粘贴分享链接，或导入 UTF-8 的 JSON、YAML 和文本文件。
4. 选择节点并点「启动」。「概览」显示本机代理地址；HTTP 和 SOCKS5 共用这个端口。手动填写地址或启用 PAC 后，应用才会使用 CLAY。
5. 关闭窗口后代理继续运行。新版的 macOS 菜单栏可直接切换节点和流量模式，也能复制地址、重新打开窗口或启停代理。「退出 CLAY」或 `⌘Q` 会结束会话；应用不会在登录 macOS 后自动启动。

### 为公开安装包准备 Mihomo

从 [Mihomo v1.19.34 官方发布](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34) 的 Assets 下载 `mihomo-darwin-arm64-v1.19.34.gz`。在下载目录校验压缩文件，再解压到用户目录：

```sh
(
  set -eu
  echo '1a7a20eca63fbbaec90137717465bfde488d0db2a3a79b8fadebf9b2545b6e4c  mihomo-darwin-arm64-v1.19.34.gz' | shasum -a 256 -c
  mkdir -p "$HOME/.local/bin"
  clay_candidate="$(mktemp "$HOME/.local/bin/.mihomo.XXXXXX")"
  trap 'rm -f "$clay_candidate"' EXIT
  gzip -dc mihomo-darwin-arm64-v1.19.34.gz > "$clay_candidate"
  printf 'a55a9073f9b7b1fa596a82c034d2dae3407ec34732102b6e42c5513ce3033f34  %s\n' "$clay_candidate" | shasum -a 256 -c
  chmod 755 "$clay_candidate"
  mv -f "$clay_candidate" "$HOME/.local/bin/mihomo-v1.19.34"
)
```

任一步的摘要不一致就停止。选文件时可按 `⌘⇧G` 输入 `~/.local/bin`，再选 `mihomo-v1.19.34`。也可以选择已信任的其他 Mihomo 可执行文件，兼容性以 v1.19.34 的验证为基准。

## 流量模式和应用接入

从新版源码构建后，可在「概览」或菜单栏切换内核流量模式：**规则**按「PAC 规则」中的已加载策略分流，**全局**让进入本机代理的流量走所选节点，**直连**让进入本机代理的流量直接访问目标。切换不会改 macOS 网络设置；已经建立的连接可能继续使用原路径。编辑规则后需重启内核来应用，PAC 则可单独更新。PAC 已判定为直连的流量不会进入内核。

| 模式 | 怎么用 | 影响范围 |
| --- | --- | --- |
| 手动接入 | 启动 CLAY 后，在需要的应用里手动填写 HTTP/SOCKS5 地址。 | 仅使用该地址的应用；不修改 macOS 网络设置。 |
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
- **订阅**可以保存多份，手动刷新、切换使用或移除。刷新失败保留上次成功的缓存；运行中变更订阅后，当前会话使用原列表，重新启动代理时应用新列表。新版会将旧 JSON 迁移成加密缓存，并将密钥单独保存到本机私有目录。请勿分享整个 CLAY 数据目录或备份；可以读取密钥的本机账户进程仍能解密。迁移后不要在旧版中编辑同一份订阅。订阅只跟随同源重定向；跨站跳转请直接填写可信的最终地址。手动导入只保留到本次应用退出。
- **诊断**可探测当前或全部节点，比较两次批量测试，复制不含节点名、服务商地址、UUID、订阅链接和原始配置的诊断报告。探测会通过节点请求 gstatic.com 的 204 地址。

**兼容范围**：VMess/VLESS 分享链接、Base64 链接列表、V2Ray/Xray JSON 出站及 Clash/Mihomo YAML 或 JSON 的内联 `proxies`。新版还支持 Shadowsocks 的 SIP002 链接和常见 AEAD 密码套件，以及 TCP/TLS Trojan 链接；同样可从 Clash 的内联节点导入，不启用插件或跳过 Trojan 证书验证。每次下载上限 2 MiB，每份最多导入 100 个兼容节点；本机回环测试允许 HTTP。导入只读取兼容节点，不执行配置里的远程提供器、策略组、规则、DNS、TUN 或入站。

## 源码与验证

```sh
bash scripts/swift-local.sh build -c release
.build/release/CLAYCoreChecks
python3 scripts/smoke-subscriptions.py .build/release/CLAYCoreChecks
```

便携工具 `clay-portable` 可检查本地节点文件和生成 PAC；macOS/Linux 还可查看指定本机 Mihomo 的流量汇总。它不接管系统网络，也不执行输入文件里的订阅或规则提供器链接。各平台验证进度见[跨平台计划](docs/跨平台路线.md)。

[参与开发](CONTRIBUTING.md) · [架构调研](docs/架构调研.md) · [验收记录](docs/验收记录.md) · [打包及发布](docs/RELEASING.md) · [安全维护](docs/安全维护.md)

CLAY 原创代码以 [MIT](https://github.com/henwanla/CLAY/blob/main/LICENSE) 许可发布。Yams 和 libyaml 各有 [上游许可证](https://github.com/henwanla/CLAY/blob/main/Vendor/Yams/UPSTREAM.md)。Mihomo 是按其 GPL 许可发布的独立依赖；本机预览包附有其许可证和固定版本的源码入口，公开 ZIP 不含该内核。
