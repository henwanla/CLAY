# 更新记录 / Changelog

## 开发中 / Unreleased

- 主窗口和菜单栏新增「连接 macOS」，区分只启动本机代理和已配置系统 PAC。系统仍在使用 CLAY 的 PAC 时保留恢复记录和监听。本机预览包内带已校验的 Mihomo。

- 菜单栏可切换节点与规则、全局、直连模式；手动接入、本机 PAC 和系统 PAC 仍独立设置。
- 扩大 Shadowsocks、Trojan 导入；订阅缓存加密，Mihomo 启动时复核已选择文件的指纹。
- 添加便携 CLI，可在本地验证节点和 PAC 规则；原生构建与验收状态见[跨平台路线](docs/跨平台路线.md)。

- Connect macOS from the window or menu bar, with a distinct local-only state. CLAY keeps its recovery record and listeners while macOS still uses its PAC URL. The local preview includes a verified Mihomo executable.
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
