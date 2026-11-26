# Android VPN 实验 / VPN lab

这个实验验证 Android 系统 TUN 能否交给 Mihomo，以及捕获上游地址时会发生什么。实验包没有正式界面，也不会进入正常的离线或 Relay APK 构建。

官方 Android Mihomo v1.19.34 能识别 `tun.file-descriptor`，但用普通应用身份运行时，初始化会试图读取 `/data/system/packages.xml`，因权限被拒而放弃启动 TUN。随附的补丁只在传入系统已打开的描述符、且关闭内核自动路由时跳过包名表读取。应用用私有 Unix 域套接字传递描述符，启动器核对对端 UID、父进程 PID，并在父进程退出时终止。

普通客户端直接连接文档保留地址；Mihomo 尝试从主机回环上的合成 HTTP 节点获取响应。TUN 只接管文档地址时，客户端收到只有合成节点知道的随机标记；将节点地址也加入 TUN 时，内核出站回到 TUN，命中实验的拒绝规则。两次会话退出后都检查临时路由是否消失。单独尝试 `addDisallowedApplication` 未能在重复测试中可靠保护内核出站，因此下一步需验证逐套接字的 `VpnService.protect()` 或显式底层网络绑定。

The official Android Mihomo v1.19.34 binary recognizes the TUN descriptor but cannot read Android's private package table as an ordinary app. The included source patch skips this step only for an externally configured descriptor with engine auto-routing disabled. The test uses a fresh response marker and checks both routing cases and cleanup. Loop prevention for full-device routing, DNS, UDP, IPv6, consent and revocation, foreground service behavior, network changes, and real devices still need separate tests.

## 复验 / Reproduce

使用独立、无其他 VPN 的 API 24 ARM64 模拟器，以及 Android Platform 35、Build Tools 36.0.0、NDK r30、JDK 17、Python 3 和 Go（实测 1.24.3）。脚本使用 [Mihomo v1.19.34 的 GitHub 源码归档](https://codeload.github.com/MetaCubeX/mihomo/tar.gz/refs/tags/v1.19.34) 并检查 SHA-256；初次编译可能需要下载 `go.sum` 固定的依赖。

```sh
export ANDROID_HOME=/absolute/path/to/android-sdk
export ANDROID_NDK_HOME=/absolute/path/to/android-ndk-r30
export JAVA_HOME=/absolute/path/to/jdk17
bash Platforms/Android/vpn-lab/run.sh emulator-5576 /absolute/path/to/mihomo-v1.19.34.tgz
```

可以用 `ADB`、`ANDROID_ADB_SERVER_PORT` 指定 ADB 和独立端口。脚本只给测试 APK 预设模拟器授权，成功时输出 `CLAY_PROBE_CAPTURE_UPSTREAM_true_PASS` 和 `CLAY_PROBE_CAPTURE_UPSTREAM_false_PASS`，退出卸载测试包并清理临时文件。它不会发布 APK 或内核；以后如需分发修改后的内核，需随版本提供相应源码、补丁、构建说明和许可。
