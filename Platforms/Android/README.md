# CLAY Android：离线检查与本机代理

CLAY 的共享节点解析和 PAC 规则已交叉编译为 Android arm64 CLI，并在 Apple Silicon 主机上的 **Android API 24 arm64 模拟器**运行通过。验证覆盖 VLESS、VMess、Shadowsocks、Trojan 链接、Clash YAML、中文文件名、合成凭据脱敏、PAC 预判和脚本生成。所有输入都是离线合成样本；脚本不会启动代理或修改设备网络。

另有 ARM64 原生 APK：粘贴本地节点文本，查看协议、传输和安全类型；输入 PAC 规则和目标，预览第一条命中规则、默认动作或本地绕过。界面随设备语言使用简体中文、英文或日文。没有联网权限，不下载订阅，不启动后台服务，不接管设备流量。CLAY 不保存输入，结果不显示节点名、地址或凭据。

GitHub Actions 检查 CLI 交叉编译、APK 构建、签名、权限与 16 KiB 对齐。下面的模拟器流量验收单独运行。

### 构建 APK

在下节的 Swift 6.4.3、Swift Android SDK、NDK r30 以外，还需要 JDK 17、Android SDK Platform 35、Android SDK Build Tools 36.0.0。将它们安装到自己的工具目录并指定路径：

```sh
export JAVA_HOME=/absolute/path/to/jdk17
export ANDROID_HOME=/absolute/path/to/android-sdk
export ANDROID_NDK_HOME=/absolute/path/to/android-ndk-r30
export SWIFT_SDKS_PATH=/absolute/path/to/swift-sdks
bash Platforms/Android/build-apk.sh --test
```

APK 默认输出到 `.build/android-apk/`；也可用 `CLAY_ANDROID_APK_DIR` 修改输出目录。预览包和测试包使用该目录的本地调试证书，只用于试用，不可当作正式发布签名。安装包支持 arm64-v8a，最低 API 23。

在已启动的独立 arm64 模拟器运行以下验收，脚本拒绝真机及已经安装了 CLAY 的模拟器。测试通过 Android Instrumentation 运行真实 Activity 和 JNI，退出时卸载测试安装：

```sh
ADB="$ANDROID_HOME/platform-tools/adb" bash Platforms/Android/smoke-apk.sh emulator-5576 \
  .build/android-apk/CLAY-Android-arm64-preview.apk \
  .build/android-apk/CLAY-Android-arm64-test.apk
```

已在 Apple Silicon 上的无窗口 Android API 24 arm64 模拟器通过上述验收，返回 `CLAY_ANDROID_PREVIEW_PASS` 和 `INSTRUMENTATION_CODE: -1`。测试用了合成配置，覆盖 VLESS 节点预览、结果脱敏、PAC 首条命中、默认动作、本地绕过和无效规则提示。APK 构建也通过了签名、16 KiB 对齐和无权限声明检查。尚未在实体设备上验证。

共享导入接受 Shadowsocks 2022 的 AES-128-GCM、AES-256-GCM 和 ChaCha20-Poly1305。Android 普通预览只显示「AEAD 2022」等分类，密钥不会出现在返回的摘要中。节点转发仍取决于所用 Relay 或 VPN 内核。

The shared importer accepts Shadowsocks 2022 with AES-128-GCM, AES-256-GCM, or ChaCha20-Poly1305. Android’s preview displays only classifications such as “AEAD 2022”; its summary omits keys. Traffic is handled by the Relay or VPN engine.

### 本机代理预览 / Local relay preview

Relay APK（`org.clayrelay.relay`）可与离线版并存。粘贴节点或选择已保存的订阅后，选择导入顺序中的节点编号和模式，点「启动本机代理」。在支持认证代理的 Android 应用手动填入 `127.0.0.1`、显示的端口和会话凭据。点「应用节点和模式」可保持监听地址不变；规则模式使用启动时填写的规则、默认动作和本地绕过设置，修改规则后须重启会话。全局将请求交给选中节点，节点失败会向客户端报错。直连会通过设备的普通网络发送请求。

此包只申请联网权限。代理和控制器仅监听 IPv4 回环，各有独立的随机会话凭据。密码在界面上按需显示、离开界面时隐藏；运行配置文件启动成功后删除。此变体不会修改系统代理设置。Android 可在后台结束进程；用完建议点「停止代理」。

The optional relay APK can be installed alongside the offline app. Paste profiles or select a saved subscription, pick a node number and routing mode, and enter the displayed loopback address and session credentials in a client that supports authenticated HTTP or SOCKS5. Apply changes to the node and mode in place. Restart the session to change the rule list, fallback, or local bypass settings. An unavailable node in Global mode results in a proxy error; Direct mode sends traffic through the device's regular connection. The relay requests Internet access only. It does not modify system proxy settings, and Android may stop it in the background.

Build with the same toolchain as the offline preview and the pinned [Mihomo v1.19.34 Android arm64 archive](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34). The script checks both the archive and the executable during packaging, and the app rechecks the packaged executable at launch. Keep the debug package local; a public build that bundles Mihomo requires a separate review of the GPL notices and corresponding source distribution.

```sh
bash Platforms/Android/build-apk.sh --test --relay /absolute/path/to/mihomo-android-arm64-v8-v1.19.34.gz
ADB="$ANDROID_HOME/platform-tools/adb" bash Platforms/Android/smoke-apk.sh --relay emulator-5576 \
  .build/android-apk/CLAY-Android-arm64-relay.apk \
  .build/android-apk/CLAY-Android-arm64-relay-test.apk
```

Relay 验收需要宿主的 Python 3 和 OpenSSL，以及能通过 `10.0.2.2` 访问宿主回环的独立模拟器。它使用合成账号和临时证书，在同一个监听端口上逐个验证 HTTP CONNECT、SOCKS5 及两者的 TLS 形式，确认错误密码和错误证书指纹不会回落到直连。该验收只覆盖 Relay 的 TCP 转发，VPN 和实体设备另验。

The Relay smoke test needs Python 3 and OpenSSL on the host and a disposable Android emulator that can reach host loopback at `10.0.2.2`. It switches between authenticated HTTP CONNECT and SOCKS5, both with and without TLS, on the same local listener. A wrong password or pin cannot reach the direct origin. The VPN test below also covers these upstreams on emulator TCP traffic. Physical devices have separate checks.

### 订阅 / Subscriptions

本机代理和 VPN 都可以在「订阅」中填写名称与 HTTPS 地址，点击下载并保存。选择「下次连接使用缓存节点」后，节点检查和下次启动使用该缓存；「使用粘贴的节点」切回粘贴的内容。手动刷新成功后，再点一次「下次连接使用缓存节点」选用新版本。已运行的会话不会因刷新、删除或切换输入而改变；若要使用新节点列表，先停止再启动。

最多可保存 12 个订阅。CLAY 仅在点击下载或刷新后发出请求，使用设备信任的 HTTPS 证书，只跟随同源跳转。传输数据和解压后的正文都不能超过 2 MiB，且正文必须含至少一个可识别节点。刷新失败时保留上次缓存。名称、地址（包括令牌）和节点缓存在各 APK 自己的应用私有目录加密保存，由各自的 Android Keystore 密钥保护，不进入系统备份。离线版没有订阅界面或联网权限。

In Relay or VPN, enter a name and an HTTPS URL under **Subscriptions**, then download and save it. **Use saved nodes for next connection** selects that snapshot for the node preview and the next session. **Use pasted nodes** returns to the pasted profiles. After a successful refresh, select **Use saved nodes for next connection** again to use the updated snapshot. Refreshing, removing, or selecting a different input does not alter a running session; stop and restart to use a new list.

Each app can save up to 12 feeds. Downloads happen only on request, use the device's HTTPS trust, follow redirects only within the same origin, and cap the transfer and decompressed body at 2 MiB each. CLAY requires at least one recognizable node before saving; a failed refresh retains the previous cache. Names, URLs (including tokens), and cached nodes are encrypted in each app's private directory with its own Android Keystore key and are excluded from system backup. The offline app has no subscription panel and no network permission.

订阅回归在独立 Android 模拟器验证 Keystore、篡改拒绝、刷新失败保留缓存和实际 Relay 转发。下载响应由测试夹具提供，没有向真实订阅地址发请求。

The emulator checks exercise Android Keystore, tamper rejection, cache retention after a failed refresh, and real Relay traffic using a saved node. Download checks supply synthetic HTTP responses through a test transport; they do not contact a real subscription provider.

### 系统 VPN 实验 / System VPN experiment

[VPN 实验](vpn-lab/README.md)在独立 Android API 24 模拟器上验证了逐套接字避环、IPv4 TCP 转发和 UDP DNS。实验使用单独的测试 APK，离线版和本机 Relay 仍不接管系统流量。

The [VPN lab](vpn-lab/README.md) verifies per-socket loop prevention, IPv4 TCP forwarding, and UDP DNS on a disposable Android API 24 emulator. Its test APK is separate from the offline and manual relay previews.

### 固定工具链

- 使用 [Swift 6.4.3](https://www.swift.org/install/) 主机工具链与 [同版本 Android SDK](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)。可使用 Swiftly 固定版本，或使用官网 macOS `.pkg`，先用 `pkgutil --check-signature` 核对 `Developer ID Installer: Swift Open Source (V9AUD2URP3)`。工作流采用解包方式，另外固定了实测 `.pkg` 的 SHA-256。
- 使用 [Google Android NDK r30](https://developer.android.com/ndk/downloads)，完整修订号 `30.0.16248370`。官方 SDK 清单的 macOS ZIP SHA-1 为 `c060be96767eefbb8e0a27796d6f43115fc1a0c4`，Linux ZIP SHA-1 为 `5107f898313790e449e87eee2183d9a20602dee9`。CI 另外固定了实测 macOS ZIP 的 SHA-256。
- 模拟器实测组合：Google Platform-Tools `37.0.3`、Android Emulator `37.3.10`（Darwin ARM64 build `16970787`）、Google APIs Android API 24 arm64-v8a r29。API 24 是目前验证版本；最低 API 为 23，APK 的目标 SDK 为 35。

```sh
swift --version
swift sdk install \
  https://download.swift.org/swift-6.4.3-release/android-sdk/swift-6.4.3-RELEASE/swift-6.4.3-RELEASE_android.artifactbundle.tar.gz \
  --checksum a78839edf4ec161e03b9f1e22a0ef94e565ece3f3ce5c03e3c79246c6b71f0a9

export ANDROID_NDK_HOME=/absolute/path/to/android-ndk-r30
bash Platforms/Android/build-portable.sh
```

本地解包时可用 `SWIFT_BIN=/absolute/path/to/swift` 选择该工具链，`SWIFT_SDKS_PATH` 指向解包后包含 `.artifactbundle` 的目录。构建脚本会打印二进制及同版 `libc++_shared.so` 的路径，并检查 Android 动态加载器 `/system/bin/linker64` 和 `AArch64` 架构。

### 在指定设备上验收

启动自己的 arm64 模拟器或连接明确授权的 Android arm64 设备，确认序列号后执行：

```sh
adb devices -l
python3 Platforms/Android/smoke-portable.py \
  /absolute/path/to/clay-portable /absolute/path/to/libc++_shared.so \
  --serial emulator-5576
```

可用 `--adb` 和 `--adb-port` 指定隔离的 ADB 安装及端口。测试只使用 `/data/local/tmp` 的随机临时目录，退出时清理。首次实测在单独 ADB 端口的无窗口模拟器中执行，未连接真机。API 24 的老加载器会报告新版 NDK 的两个 ELF 元数据提示；脚本只过滤原样匹配的提示，其余成功命令的标准错误仍会使测试失败。

### 节点选择 / Node picker

本机代理和 VPN 都可以点「选择节点」，查看当前来源的名称、协议和传输方式。默认选首个兼容节点。已连接时，从该会话的节点列表选择并点「应用节点和模式」；编辑粘贴文本或改用订阅缓存只影响下次启动，运行中的节点列表和连接保持原样。普通节点预览和系统磁贴不显示私密名称；选择窗口受 Android 截屏保护。

In Relay and VPN, **Select node** lists local display names, protocols, and transports. The first compatible node is selected by default. While connected, choose from the active session's list and tap **Apply node and mode**. Editing pasted input or selecting another cache affects the next session. The node picker is protected from screenshots; the ordinary preview and system tile omit names.

### 切换节点和模式 / Switching nodes and modes

VPN 和 Relay 在节点或模式真正改变后会关闭内核跟踪的旧连接，让应用重新连接并采用新路径。重复选择当前节点和模式不关闭连接。绕过内核的连接不受影响。

VPN and Relay close existing connections tracked by the core when the selected node or mode changes. Apps can then reconnect on the new route. Reselecting the current route leaves connections open; traffic outside the core is unaffected.

### 会话流量 / Session traffic

VPN 和 Relay 在确认启动后，约每两秒从本地内核读取一次累计上传、下载以及最近一秒的速率。统计的是经过该内核的流量，不是设备总流量；换节点或模式仍沿用同一会话累计值，停止后清空面板。App 退到后台时暂停采样，已建立的 VPN 不受影响。读数不保存，也不进入快捷设置、通知或日志。

After VPN or Relay confirms the session, the foreground panel samples totals and the last one-second rates from the local core about every two seconds. These are core counters, not device-wide usage. Changing nodes or routing modes keeps the same session totals. Stopping clears the panel, and sampling pauses in the background without stopping the VPN. Readings stay off disk, out of the system tile and notification, and out of logs.

### VPN 技术预览 / VPN technical preview

另一个 ARM64 调试 APK（Android 8.0+，包名 `org.clayrelay.vpn`）可和离线版及本机代理版共存。先选择订阅缓存或粘贴节点，填入可选规则和一个可信 DNS 的 IPv4 或 IPv6 字面地址，选择节点与模式，点「启动 VPN」并确认 Android 系统提示。关闭界面后由前台服务继续运行，可在通知、快捷设置磁贴或应用内停止。通知显示隧道正在启动、切换、运行或停止，不显示节点、订阅或地址；旧通知的停止操作不会影响重启后的会话。隧道运行不代表远端节点可达。节点和模式从内核读回，变更时会结束现有连接。规则更新需重新启动会话。

从屏幕顶端拉下快捷设置，编辑磁贴并添加「CLAY VPN」。未连接时点磁贴打开应用，由你选择配置并启动；已连接时点「停止 VPN」，在设备锁定时需先解锁。磁贴只显示连接动作，不显示节点、订阅或地址。

VPN 接管 IPv4 和 IPv6。全局模式下两种流量都交给选定节点，节点拒绝或无法连接时不回落到直连。规则模式支持 IPv6 精确地址和网段，例如 `DOMAIN,2001:db8::42,DIRECT` 或 `IP-CIDR6,2001:db8:1::/48,PROXY`，网段匹配不会主动解析域名。若命中的规则要求走代理、所选节点又不支持 UDP，普通 UDP 流量会被丢弃；显式直连规则仍然生效。连接节点本身可走 IPv4 或 IPv6，访问目标则需要节点支持相应地址族。直连模式由隧道内核连接原站，IPv6 直连需要底层网络可达。此预览不支持始终开启或断网保护。停止、撤销或进程退出后，设备会恢复普通网络。DNS 地址只填 IP，不加方括号、端口或接口名；CLAY 不解析 DNS 主机名。设备发往所填 DNS 的流量按当前模式和规则转发。路由指向只支持 TCP 的节点时，Android 可对同一 DNS 地址的 53 端口改用 TCP，不会改用其他 DNS 或回落直连。请选能从代理端访问、支持 TCP 的解析器；TCP 本身不加密 DNS。节点域名的引导解析仍可能使用系统 DNS。Private DNS、加密 DNS、网络切换和真机仍需验证。当前公开 Release 没有 VPN 安装包。

配置了域名规则时，规则模式可在本地用可见的 HTTP Host（TCP 80、8000、8080、8081、8888）或 TLS SNI（TCP 443、8443、9443）匹配规则。原目的 IP 和端口保持不变，CLAY 不解密 TLS，也不记录这些域名。看不到域名时（如其他端口、QUIC 或 ECH 隐藏的内层名称），按剩余的 IP 规则及兜底规则处理；域名分流不应当作访问隔离。

The separate Android 8.0+ ARM64 APK accepts saved subscriptions or pasted profiles, plus optional rules. Enter one trusted DNS server as a literal IPv4 or IPv6 address, then choose a node and mode, then confirm Android's VPN prompt. The service can outlive the screen. Stop it in the app, from its notification, or using its Quick Settings tile. The notification shows whether the tunnel is starting, switching, active, or stopping without disclosing nodes, subscriptions, or addresses. Its Stop action cannot affect a later session. An active tunnel does not imply the remote node is reachable. Node and mode changes are confirmed by the engine and close existing connections. Restart to change the rules.

Add **CLAY VPN** from the system's Quick Settings editor. When disconnected, the tile opens the app so you can select a profile and start it. When connected, it can stop the current session, after unlocking if needed. It shows no node, subscription or address information.

The VPN handles both IPv4 and IPv6. Global mode sends both to the selected node without falling back to the origin when the node cannot connect. Rule mode accepts exact IPv6 addresses and ranges, such as `DOMAIN,2001:db8::42,DIRECT` and `IP-CIDR6,2001:db8:1::/48,PROXY`. CIDR rules do not trigger DNS lookups. If a matching rule requires a proxy and the selected node does not support UDP, the VPN drops ordinary UDP traffic. Explicit Direct rules still work. Direct mode needs an underlying network that can reach the origin in the requested address family. This preview does not support always-on VPN or a kill switch. Normal networking resumes after stop, revocation, or process exit. Enter the DNS address without brackets, a port, or an interface zone. CLAY does not resolve DNS server hostnames. Traffic to the configured DNS follows the selected routing policy. On a TCP-only route, Android can retry against the same resolver on TCP port 53, without falling back to another resolver or Direct. Use a resolver reachable through the selected node that accepts TCP. TCP does not encrypt DNS, and node hostnames may still use system DNS for bootstrap. Private DNS, encrypted DNS, network changes, and physical devices still need testing. There is no public VPN APK yet.

When the VPN has domain rules, Rule mode can match a visible HTTP Host (TCP 80, 8000, 8080, 8081, 8888) or TLS SNI (TCP 443, 8443, 9443) locally. CLAY keeps the original destination IP and port, does not decrypt TLS, and does not log the extracted names. Connections without a visible name, including other ports, QUIC, or names hidden by ECH, follow the remaining IP and fallback rules. Domain routing is not an access control boundary.

The build verifies the exact [Mihomo v1.19.34 source archive](https://codeload.github.com/MetaCubeX/mihomo/tar.gz/refs/tags/v1.19.34) and uses Go 1.24.3, the NDK and the Swift tools above. Corresponding engine source consists of that archive, [the TUN patch](vpn-lab/external-tun.patch), [the socket hook](vpn-lab/protect_android.go), [the DNS retry hook](vpn-lab/dns_tcp_retry.go), and the [build recipe](build-vpn-engine.sh). Any distributed APK must ship corresponding source and license materials for that build.

```sh
bash Platforms/Android/build-apk.sh --test --vpn /absolute/path/to/mihomo-v1.19.34.tgz
ADB="$ANDROID_HOME/platform-tools/adb" bash Platforms/Android/smoke-vpn.sh emulator-5578 \
  .build/android-apk/CLAY-Android-arm64-vpn.apk \
  .build/android-apk/CLAY-Android-arm64-vpn-test.apk \
  .build/android-apk/CLAY-Android-arm64-vpn-revoker.apk
```

复验需要 Python 3、OpenSSL 和可丢弃的 Android 15 ARM64 模拟器，要求默认 QEMU 回环别名能访问本机测试服务：IPv4 为 `10.0.2.2`，IPv6 为 `fec0::2`。复验检查系统授权取消、两个分别使用 IPv4、IPv6 地址的 VLESS 节点转发的双栈 TCP 与 UDP DNS、IP 规则、全局／直连、后台运行、两种停止方式与同进程重启。两轮分别把 IPv4 和 IPv6 配置为唯一的 DNS 地址。每轮的两个合成域名只在对应的 DNS 地址上有应答；Android 将它们解析到同一 IPv4，在 HTTP 和 TLS 下各自走代理或直连。测试节点只接受原目的 IP 和端口。TLS 证书只由测试客户端信任。复验保留旧通知的停止操作，确认会话重启后它已被撤销，而新通知仍能停止新会话。磁贴用同一控制路径验证当前会话能停止、旧操作不能停止新会话；模拟器未操作系统下拉面板或锁屏。它还强制停止应用自己的内核，再由一个独立、无联网权限的测试包请求系统 VPN 授权，核对 CLAY 响应实际撤销并清除进程、路由和通知。连接前后检查 IPv6 原站可达。连接期间用不同应答验证 IPv6 换节点、IPv6 网段规则的顺序、直连和后台转发。全局模式下，节点拒绝的目标不会回落到原站。规则模式下还切换到不支持 UDP 的节点：指定直连的 IPv6 UDP 可达，指定走代理的 IPv4 UDP 既没有收到回包，原站也没有收到数据。脚本检查 IPv6 默认路由已指向 VPN、结束后无残留隧道路由。

The test uses Python 3, OpenSSL, and a disposable Android 15 ARM64 emulator with QEMU's default host loopback aliases (`10.0.2.2` and `fec0::2`). It checks system consent cancellation, TCP and UDP DNS to IPv4 and IPv6 destinations through two VLESS nodes with IPv4 and IPv6 addresses respectively, routing modes, background operation, both stop controls, and same-process restart. The two runs configure an IPv4 and an IPv6 DNS server respectively. Each run uses two synthetic names answered only at the configured resolver address; Android resolves them to the same IPv4 address. The test verifies that Rule mode sends one through the proxy and one directly for both HTTP and TLS. The test node only accepts the original destination IP and port. Only the test client trusts the temporary TLS certificate. It verifies that an old notification's Stop action is cancelled after a restart and that the fresh notification can still stop the running tunnel. It also exercises the tile's stop handler on a live VPN, including rejecting a stale request after restart. It does not interact with the system tile or lock screen. It forcibly terminates CLAY's own engine and separately transfers VPN authorization to a test-only app with no network permissions. Both cases must clear the engine, routes, notification, and private runtime files. IPv6 TCP reaches the host before and after the VPN. While connected, distinct responses prove IPv6 node switching, the order of overlapping CIDR rules, Direct mode, and background forwarding. A reachable IPv6 origin refused by both proxy fixtures must remain unreachable in Global mode. In Rule mode with a TCP-only node, an explicit IPv6 Direct rule still passes UDP. A reachable IPv4 UDP origin must receive no packets marked for the proxy. The script checks the IPv6 default route during the tunnel and checks for leftover tunnel routes after cleanup. The script removes all three APKs after the test.

VPN 转发回归还用普通 IPv4 TCP 套接字，在同一系统隧道依次切换带认证的 HTTP CONNECT、SOCKS5 和各自的 TLS 变体。测试误填密码和证书指纹时，原站没有收到标记请求；切回有效节点可恢复，停止后原站重新直达。未使用真实节点，也未在实体手机上运行。

The VPN forwarding check also sends ordinary IPv4 TCP through the same system tunnel while switching between authenticated HTTP CONNECT, SOCKS5, and their TLS variants. Wrong credentials and certificate pins never send the marked request to the reachable direct origin. Switching back restores forwarding, and stopping restores direct access. The upstreams are local fixtures; physical devices are outside this check.

The DNS checks cover raw UDP packets and Android system lookups via the configured IPv4 or IPv6 resolver. With a TCP-only node, fresh lookups in Rule and Global modes must both return the synthetic answer from the selected node over TCP. They do not validate resolver fallback, Private DNS, or encrypted DNS. The emulator first cancels the platform prompt using Android's activity result mechanism, then preauthorizes the fixtures for subsequent cases. Physical device prompts and recovery still need manual verification.
