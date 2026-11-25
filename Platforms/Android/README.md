# CLAY Android：离线内核验收

CLAY 的共享节点解析和 PAC 规则已交叉编译为 Android arm64 CLI，并在 Apple Silicon 主机上的 **Android API 24 arm64 模拟器**运行通过。验证覆盖 VLESS、VMess、Shadowsocks、Trojan 链接、Clash YAML、中文文件名、合成凭据脱敏、PAC 预判和脚本生成。所有输入都是离线合成样本；脚本不会启动代理或修改设备网络。

目前产物是 `clay-portable` 的 ARM64 ELF。尚无 Android APK、界面、JNI 接口或 `VpnService`，也没有 Android 真机运行记录。独立 GitHub Actions 工作流只检查交叉编译和 ELF 架构；设备执行通过下方 ADB 验收复现。

### 固定工具链

- 使用 [Swift 6.4.3](https://www.swift.org/install/) 主机工具链与 [同版本 Android SDK](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)。可使用 Swiftly 固定版本，或使用官网 macOS `.pkg`，先用 `pkgutil --check-signature` 核对 `Developer ID Installer: Swift Open Source (V9AUD2URP3)`。工作流采用解包方式，另外固定了实测 `.pkg` 的 SHA-256。
- 使用 [Google Android NDK r30](https://developer.android.com/ndk/downloads)，完整修订号 `30.0.16248370`。官方 SDK 清单的 macOS ZIP SHA-1 为 `c060be96767eefbb8e0a27796d6f43115fc1a0c4`，Linux ZIP SHA-1 为 `5107f898313790e449e87eee2183d9a20602dee9`。CI 另外固定了实测 macOS ZIP 的 SHA-256。
- 模拟器实测组合：Google Platform-Tools `37.0.3`、Android Emulator `37.3.10`（Darwin ARM64 build `16970787`）、Google APIs Android API 24 arm64-v8a r29。可用更高版本的 arm64 Android 重跑；API 24 是目前实际验证版本，编译目标设置为 API 23。

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
