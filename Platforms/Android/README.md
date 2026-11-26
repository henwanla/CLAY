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

### 本机代理预览 / Local relay preview

Relay APK（`org.clayrelay.relay`）可与离线版并存。粘贴节点后，选择导入顺序中的节点编号和模式，点「启动本机代理」。在支持认证代理的 Android 应用手动填入 `127.0.0.1`、显示的端口和会话凭据。点「应用节点和模式」可保持监听地址不变；规则模式使用启动时填写的规则、默认动作和本地绕过设置，修改规则后须重启会话。全局将请求交给选中节点，节点失败会向客户端报错。直连会通过设备的普通网络发送请求。

此包只申请联网权限。代理和控制器仅监听 IPv4 回环，各有独立的随机会话凭据。密码在界面上按需显示、离开界面时隐藏；运行配置文件启动成功后删除。没有全设备 VPN、后台常驻保证、联网订阅刷新或系统代理设置。Android 可在后台结束进程；用完建议点「停止代理」。

The optional relay APK can be installed alongside the offline app. Paste profiles, pick a node number and routing mode, and enter the displayed loopback address and session credentials in a client that supports authenticated HTTP or SOCKS5. Apply changes to the node and mode in place. Restart the session to change the rule list, fallback, or local bypass settings. An unavailable node in Global mode results in a proxy error; Direct mode sends traffic through the device's regular connection. The relay requests Internet access only and provides no VPN, guaranteed background service, subscription downloads, or system proxy configuration.

Build with the same toolchain as the offline preview and the pinned [Mihomo v1.19.34 Android arm64 archive](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34). The script checks both the archive and the executable during packaging, and the app rechecks the packaged executable at launch. Keep the debug package local; a public build that bundles Mihomo requires a separate review of the GPL notices and corresponding source distribution.

```sh
bash Platforms/Android/build-apk.sh --test --relay /absolute/path/to/mihomo-android-arm64-v8-v1.19.34.gz
ADB="$ANDROID_HOME/platform-tools/adb" bash Platforms/Android/smoke-apk.sh --relay emulator-5576 \
  .build/android-apk/CLAY-Android-arm64-relay.apk \
  .build/android-apk/CLAY-Android-arm64-relay-test.apk
```

### 系统 VPN 实验 / System VPN experiment

[VPN 实验](vpn-lab/README.md)在独立 Android API 24 模拟器上验证了有限范围的 IPv4 TCP 转发，并复现出站绕回。实验使用单独的测试 APK，离线版和本机 Relay 仍不接管系统流量。

The [VPN lab](vpn-lab/README.md) verifies limited IPv4 TCP forwarding and reproduces an outbound routing loop on a disposable Android API 24 emulator. Its test APK is separate from the offline and manual relay previews.

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
