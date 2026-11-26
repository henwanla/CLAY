# CLAY for Linux · Desktop preview

Use this GTK 3 window to load nodes from a local profile, start a SHA-256 verified Mihomo executable, switch nodes and routing modes, and copy the local proxy address. It uses the same managed session as the Linux portable CLI.

On Ubuntu 24.04, install Python 3, GTK 3 bindings, and the runtime tools, then build the CLI from the repository root:

```sh
sudo apt install python3-gi gir1.2-gtk-3.0 curl coreutils
swift build -c release --product clay-portable
/usr/bin/python3 Platforms/Linux/clay-desktop.py --cli .build/release/clay-portable
```

1. Pick a local profile or a downloaded subscription file and click **Load nodes**. Node numbers follow the CLI import order. For privacy the picker shows only protocol, transport and security, without names or server addresses. If you edit the file, load it again.
2. Choose the extracted Mihomo executable for your architecture and enter the expected SHA-256 of the executable. If the publisher supplies only an archive checksum, verify the archive first, then use `sha256sum` on the extracted executable.
3. Select a node and routing mode. For Rule mode, you can choose a file of CLAY PAC rules. **Start session** starts a manual proxy. A loopback address appears after Mihomo reports the requested settings. Enter it in individual applications as their HTTP or SOCKS5 proxy.
4. To change nodes or mode in the running session, select the new value and click **Apply**. If a change cannot be confirmed, click **Refresh status** to check the current state. Click **Stop** to end the session or **Quit CLAY** to stop and exit.

For the optional tray, install `gir1.2-ayatanaappindicator3-0.1` and use a desktop panel with StatusNotifierItem/AppIndicator support. When CLAY confirms a tray host, closing the window during a session keeps the proxy running. Open the tray menu to reopen CLAY, switch mode or node, refresh, stop, or quit. The menu shows up to 12 node numbers; **All nodes…** reopens the full picker. **Quit CLAY** in either place stops and exits. If the tray goes away while the window is hidden, CLAY brings the window back. Without the binding or a confirmed host, closing the window stops the session as before.

On GNOME, **Connect GNOME** starts the core and applies a PAC to apps that follow GNOME proxy settings. If a manual session is running, choose **Apply to GNOME** from the window or tray. The PAC keeps local destinations direct and sends other requests to Mihomo, where Rule, Global and Direct take effect. Switching modes or nodes does not replace the PAC URL. Manual usage remains available on other desktops or when system proxy settings are locked.

Use **Restore GNOME proxy** to restore the previous GNOME mode and script without stopping the core. Stop and Quit restore settings that CLAY still owns before closing the listener. If the process is terminated abruptly, reopen CLAY in GNOME to recover. If another app changes the settings, CLAY preserves newer values. If the script still points to CLAY but the mode or address no longer matches, remove CLAY's script address in GNOME Network Proxy and retry. The recovery snapshot is stored locally with owner-only permissions; it may contain the prior PAC URL and is removed after recovery. It isn't sent anywhere. KDE system proxy, TUN, login startup and remote subscription refresh are outside this preview. The tray exports node numbers and confirmed modes to the local session bus; profile paths, engine logs and node credentials are not included.

## 中文说明

Linux 桌面预览可以读取本地节点配置、启动通过 SHA-256 校验的 Mihomo，并在会话中切换节点和路由模式。请在仓库根目录运行上面的安装、构建和启动命令。

1. 选择本地配置或已下载的订阅文件，点 **Load nodes**。编号和命令行导入顺序一致，列表只显示协议、传输类型和安全模式。修改文件后请重新加载。
2. 选择解压后的 Mihomo 可执行文件，填写该文件的预期 SHA-256。若上游只提供压缩包校验值，先验证压缩包，再计算解压后的文件哈希。
3. 选好节点和模式，按需为 Rule 模式添加 CLAY PAC 规则文件。**Start session** 启动手动代理，内核确认后会显示 HTTP／SOCKS5 本机地址，可在需要代理的应用中填写。
4. 运行时可通过 **Apply** 切换，结果未确认时可用 **Refresh status** 重新核对。点击 **Stop** 停止代理，**Quit CLAY** 停止并退出。

可选托盘：安装上面的 Ayatana 绑定，并使用支持 StatusNotifierItem／AppIndicator 的桌面面板。确认托盘可用后，运行中关闭窗口会保留会话。可从托盘打开窗口、切换节点和规则／全局／直连，或刷新、停止和退出。菜单显示最多 12 个节点编号，**All nodes…** 可打开完整列表。托盘消失时会重新显示窗口；绑定未安装或托盘未确认时，关闭窗口会停止代理并退出。

在 GNOME 中可用 **Connect GNOME** 启动并应用系统 PAC。手动会话已启动时，可从窗口或托盘选择 **Apply to GNOME**。遵循 GNOME 代理设置的应用会保留本地地址直连，其他流量交给内核的规则／全局／直连模式。切节点或模式不改变 PAC 地址。其他桌面或系统设置锁定时仍可手动接入。

**Restore GNOME proxy** 恢复原 GNOME 模式和脚本地址，同时保留内核。停止或退出会先恢复仍由 CLAY 管理的设置，再关监听。异常退出后，在 GNOME 重新打开 CLAY 会尝试恢复。检测到外部新设置时会保留；若脚本仍指向 CLAY，但模式或地址已被改过，请在 GNOME 的「网络代理」中移除 CLAY 脚本地址，再重试。恢复记录保存在当前用户专用目录，可能包含原 PAC 地址，恢复后删除，不会上传。暂不支持 KDE 系统代理、TUN、开机启动和在线订阅刷新；托盘不展示节点名、服务器或凭据。

## Synthetic checks / 测试

The adapter check works on macOS or Linux. Ubuntu’s GTK check uses the real Linux CLI, a synthetic engine, private dconf storage, and a tray watcher on a private session bus. It verifies exported menu actions, independent system settings readback, restart recovery and background cleanup without external network access, a real desktop panel, or a browser.

```sh
python3 Platforms/Linux/smoke-desktop.py .build/release/clay-portable --adapter-only
sudo apt install gir1.2-ayatanaappindicator3-0.1 dbus-daemon xvfb xauth gsettings-desktop-schemas dconf-gsettings-backend dconf-service libglib2.0-bin
bash Platforms/Linux/smoke-gnome.sh .build/release/clay-portable
```
