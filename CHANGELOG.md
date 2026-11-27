# 更新记录 / Changelog

## 开发中 / Unreleased

- Android VPN 使用 TCP 专用节点时，系统可对设定的 IPv4 或 IPv6 DNS 改用 TCP，继续遵守规则和全局模式。不改变其他 UDP 流量的路由。
- Android VPN can retry DNS over TCP at the configured IPv4 or IPv6 resolver when using a TCP-only node. The query follows Rule or Global mode, and other UDP traffic keeps its existing routing.

## 0.3.5 · 桌面预览 / Desktop preview

- 可从 Clash 内联配置导入 HTTP CONNECT 和 SOCKS5 TCP 上游，支持身份认证和 TLS，也可粘贴普通 SOCKS5 链接。
- Import HTTP CONNECT and SOCKS5 TCP upstreams from inline Clash profiles, with authentication and TLS. Plain SOCKS5 links can also be pasted.
- Android、iOS 和 macOS 的节点界面正确显示 HTTP CONNECT 和 SOCKS5，Android 节点选择器也标明 TLS。Android Relay 模拟器验收确认错误密码或证书指纹不会回落到直连。
- Android, iOS, and macOS show the HTTP CONNECT and SOCKS5 protocol names. Android marks TLS in the node picker, and its Relay emulator tests confirm that a wrong password or pin cannot fall back to direct.
- Android VPN 预览接管 IPv6，连同 IPv4 走当前节点及规则、全局或直连模式；全局模式下，失效的代理路径不会回落到 IPv6 直连。
- The Android VPN preview routes IPv6 alongside IPv4 with node switching and Rule, Global, or Direct mode. A failed proxy path does not fall back to direct IPv6 in Global mode.
- 规则预览、PAC 脚本和内核规则支持 IPv6 网段。Android VPN 拒绝节点不支持的代理 UDP 流量，明确设置为直连的规则照常工作。
- Rule previews, PAC scripts, and engine rules support IPv6 CIDR. Android VPN drops proxied UDP traffic when the selected node lacks UDP support; explicit Direct rules still work.
- Android VPN 的 DNS 输入可填写一个 IPv4 或 IPv6 地址，系统解析仍按当前节点和规则转发。
- Android VPN accepts one IPv4 or IPv6 DNS address. System lookups still follow the active node and routing policy.
- iOS 隧道实验可为一个 IPv4 或 IPv6 端点转发 TCP 与节点支持的 UDP。宿主回环验证了换节点、关闭旧 UDP 会话和拒绝范围外数据包；签名真机验证待完成。
- The iOS Tunnel Lab forwards TCP and supported UDP for one IPv4 or IPv6 endpoint. Host loopback tests cover node switching, retiring old UDP sessions, and out-of-scope packet rejection; signed device testing is still pending.
- Windows 和 Linux 开发版可在连接前检查规则文件，输入域名、IP 或 URL 可离线预览命中的规则。
- Windows and Linux development builds check local rule files and preview a domain, IP address, or URL offline before connecting.
- Windows 和 Linux 开发版按文件内容识别指定的官方 Mihomo，自动填写预期 SHA-256；选错文件时会说明处理方式。
- Windows and Linux development builds recognize the pinned upstream Mihomo by content and fill in its expected SHA-256. Errors explain how to correct the selection.
- Windows 和 Linux 的会话面板自动显示上传、下载速率与累计流量。窗口最小化或收进托盘时暂停采样，数据只留在本机内存。
- The Windows and Linux session panels show live upload and download rates and session totals. Sampling pauses while the window is minimized or hidden in the tray. Traffic counts stay in local memory.

## 0.3.4 · 桌面预览 / Desktop preview

- macOS 试用包可直接切回随附 Mihomo。外部内核移走或校验失败时，显示恢复方式并保持停止。菜单栏显示节点编号及协议，主窗口保留节点名。公开包仍需单独准备已校验的 Mihomo。
- 共享导入和 Mihomo 会话支持 Shadowsocks 2022。支持三种套件的导入；AES-128-GCM 已用合成节点验证实际转发。
- Android VPN 预览的通知显示启动、切换、运行或停止，不显示节点或订阅；旧通知不能停止之后的会话。iOS 隧道实验可为每次实验指定 IPv4 测试端点。移动端仍为源码预览。

- Local macOS previews can switch back to the bundled Mihomo. A missing or changed external executable leaves the session stopped with recovery guidance. The menu bar shows node numbers and protocols; full names stay in the window. Public downloads still require a separately verified Mihomo.
- The shared importer and Mihomo sessions support Shadowsocks 2022. Three ciphers are accepted on import; AES-128-GCM forwarding was verified with a synthetic node.
- The Android VPN preview notification displays the tunnel phase without exposing profiles, and its Stop action cannot affect a later session. The iOS Tunnel Lab accepts a test IPv4 endpoint for each run. Mobile builds remain source previews.

## 0.3.3 · 桌面预览 / Desktop preview

- macOS、Windows 和 Linux 实际切换节点或流量模式后，等待内核关闭其跟踪的已有连接；重复选择当前项不会中断。状态未确认时不会显示切换成功。
- Windows x64 与 Ubuntu 24.04 x86-64 提供桌面下载包，含手动代理、托盘、系统 PAC 和加密订阅缓存。三个公开包均需要单独准备已校验的 Mihomo。
- 增加 TUIC v5 兼容；Windows 和 Linux 的主窗口显示节点名，托盘只显示编号。
- Android VPN 技术预览修复部分端口的 HTTP 和 TLS 域名规则；iOS 隧道实验支持加密订阅缓存和会话中换节点。移动端仍是源码预览，待签名真机验收。

- CLAY waits for the core to close tracked connections after changing the node or routing mode on macOS, Windows, and Linux. Reselecting the active option keeps connections open. Failed confirmation appears as an unconfirmed state.
- Download desktop previews for Windows x64 and Ubuntu 24.04 x86-64 with a manual proxy, tray controls, system PAC, and encrypted subscription caches. All three desktop downloads require a separately verified Mihomo executable.
- Add TUIC v5 support. Windows and Linux show node names in the window and only node numbers in the tray.
- The Android VPN preview fixes HTTP and TLS domain rules on selected ports. The iOS Tunnel Lab adds encrypted subscription caching and in-session node switching. Mobile builds remain source previews pending signed device tests.

## 0.3.2 · 预览版 / Preview

- macOS 的「连接 macOS」现在将非本地请求交给当前的规则／全局／直连模式。可从 PAC 页面单独应用自定义 PAC；macOS 尚未切换到新地址时，CLAY 保留旧监听。模式和节点切换由内核读回确认。
- Connect macOS now sends non-local requests through the current Rule, Global, or Direct mode. Custom PAC is still available separately. CLAY keeps the old PAC listener while macOS applies a replacement, and verifies mode and node changes by reading back the core state.

同时保留跨平台源码预览 / Cross-platform previews in the source tree:

- Windows 便携 CLI 支持在同一回环会话内切换节点和规则／全局／直连，切换状态由内核读回确认。
- The Windows portable CLI can switch nodes and Rule, Global, or Direct mode in a running loopback session, with controller readback before confirmation.
- Windows 新增中英日桌面预览，关闭窗口后可从托盘切节点、切模式或停止手动代理。
- Add a Windows desktop preview that keeps the manual proxy accessible from the tray, in English, Simplified Chinese, and Japanese.
- Android 增加独立的本机代理预览：手动接入认证 HTTP/SOCKS5，在同一监听地址切换节点及规则／全局／直连。离线检查版仍无联网权限。
- Add a separate Android relay preview for authenticated loopback HTTP/SOCKS5, with in-place switching between nodes and Rule, Global, or Direct. The offline preview still has no network permission.

## 0.3.1 · 预览版 / Preview

- 主窗口和菜单栏新增「连接 macOS」，区分本机代理、系统 PAC 已配置和系统默认 PAC 已生效。系统仍在使用 CLAY 的 PAC 时保留恢复记录和监听。本机预览包内带已校验的 Mihomo。

- 菜单栏可切换节点与规则、全局、直连模式；手动接入、本机 PAC 和系统 PAC 仍独立设置。
- 扩大 Shadowsocks、Trojan 导入；订阅缓存加密，Mihomo 启动时复核已选择文件的指纹。
- 添加便携 CLI，可在本地验证节点和 PAC 规则；原生构建与验收状态见[跨平台路线](docs/跨平台路线.md)。

- Connect macOS from the window or menu bar, and distinguish a local-only session, configured PAC, and effective default PAC. CLAY keeps its recovery record and listeners while macOS still uses its PAC URL. The local preview includes a verified Mihomo executable.
- Switch nodes and Rule, Global, or Direct from the menu bar. Manual connection, local PAC, and system PAC remain separately configured.
- Import a supported subset of Shadowsocks and Trojan profiles. The subscription cache is encrypted, and the app rechecks the selected Mihomo executable's fingerprint before launching it.
- Add a portable CLI for local profile and PAC validation. See the [platform roadmap](docs/跨平台路线.md) for build and verification status.

## 0.3.0 · 预览版 / Preview

- 新增独立代理、本机 PAC、系统 PAC 三种启用方式。PAC 支持按顺序编辑和批量导入规则、测试规则命中、设置默认行为；系统 PAC 可在停止、退出或重开后恢复原网络服务的代理设置。
- 「概览」显示实时流量和会话累计量；「连接」支持搜索、排序、关闭单条或全部连接。
- 首个公开包面向 Apple Silicon，须单独安装 Mihomo。保留含已校验 Mihomo 的本机预览打包方式。

- Added standalone proxy, local PAC, and macOS system PAC modes. PAC includes an ordered rule editor, bulk import, match preview, and default routing. System PAC saves the selected network service’s previous proxy settings for restoration.
- Added live traffic and session totals in Overview, and searchable, sortable connections with individual or bulk close controls.
- The public Apple Silicon package requires a separate Mihomo install. Local preview packaging can still include a verified core.

## 0.2.0 · 预览版 / Preview

- 新增多订阅管理和本地缓存，刷新失败时继续使用上一份可用节点。支持从 Clash/Mihomo YAML 或 JSON 的 `proxies` 中提取 VMess/VLESS 节点。
- 支持菜单栏查看代理状态和启停；关闭主窗口保留当前代理会话。

- Added multiple subscriptions with local caching and parsing of VMess/VLESS entries from Clash/Mihomo `proxies` lists. A failed refresh preserves the last good list.
- Added menu bar controls. Closing the main window keeps the proxy running.

## 0.1.0 · 预览版 / Preview

- 首个原生 macOS 版本，支持 VMess/VLESS 节点导入、独立回环代理、节点切换和诊断。
- First native macOS preview with VMess/VLESS import, an independent loopback proxy, node switching, and diagnostics.
