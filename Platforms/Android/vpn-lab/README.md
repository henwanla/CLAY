# Android VPN 实验 / VPN lab

这个实验验证 Android 如何把系统 TUN 交给 Mihomo，并用 `VpnService.protect()` 避免内核的出站套接字绕回自己的 TUN。实验包没有正式界面，也不会进入正常的离线或 Relay APK 构建。

官方 Android Mihomo v1.19.34 能识别 `tun.file-descriptor`，但用普通应用身份运行时，初始化会试图读取 `/data/system/packages.xml`，因权限被拒而放弃启动 TUN。随附的补丁只在传入系统已打开的描述符、且关闭内核自动路由时跳过包名表读取。应用用私有 Unix 域套接字传递描述符，启动器核对对端 UID、父进程 PID，并在父进程退出时终止。

启动器保留已验证对端的 Unix 通道。测试内核通过 `DefaultSocketHook` 在拨号前向服务发送套接字副本，服务调用系统保护接口后才回复。拒绝、超时、断开或无效回复均令本次拨号失败。测试覆盖的是接入该 hook 的 TCP 和 UDP DNS 路径，不能代替所有协议的审核。

三组实验保留相同的 IPv4 路由，并把上游地址也纳入 TUN。关闭保护时，内核出站绕回并命中拒绝规则；服务拒绝保护时，内核报错且不拨号；保护成功时，普通客户端收到合成 HTTP 节点的随机标记，发往虚拟 DNS 地址的 UDP 查询也收到本轮本地解析器的预期回答。每组退出后都检查临时路由已清除。DNS 夹具没有验证全局模式下的加密 DNS、规则分流或系统私密 DNS。

The test forwards the platform TUN and uses the same private channel for socket protection. With identical IPv4 routes, including the upstream address, the lab checks a routing loop with protection off, no dialing after denial, and successful TCP and UDP DNS with protection on. DNS, general UDP protocol coverage, IPv6, consent and revocation, foreground service behavior, network changes, and physical devices still need product testing.

## 复验 / Reproduce

使用独立、无其他 VPN 的 API 24 ARM64 模拟器，以及 Android Platform 35、Build Tools 36.0.0、NDK r30、JDK 17、Python 3 和 Go（实测 1.24.3）。脚本使用 [Mihomo v1.19.34 的 GitHub 源码归档](https://codeload.github.com/MetaCubeX/mihomo/tar.gz/refs/tags/v1.19.34) 并检查 SHA-256；初次编译可能需要下载 `go.sum` 固定的依赖。

```sh
export ANDROID_HOME=/absolute/path/to/android-sdk
export ANDROID_NDK_HOME=/absolute/path/to/android-ndk-r30
export JAVA_HOME=/absolute/path/to/jdk17
bash Platforms/Android/vpn-lab/run.sh emulator-5576 /absolute/path/to/mihomo-v1.19.34.tgz
```

可以用 `ADB`、`ANDROID_ADB_SERVER_PORT` 指定 ADB 和独立端口。脚本只给测试 APK 预设模拟器授权，成功时输出 `CLAY_PROBE_PROTECT_off_PASS`、`CLAY_PROBE_PROTECT_deny_PASS`、`CLAY_PROBE_PROTECT_on_PASS` 和 `CLAY_PROBE_DNS_UDP_PASS`；结束后移除测试客户端、卸载测试包并清理临时文件。它不会发布 APK 或内核；以后如需分发修改后的内核，需随版本提供相应源码、补丁、构建说明和许可。
