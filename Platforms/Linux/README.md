# CLAY for Linux · Desktop preview

Use this GTK 3 window to load nodes from a local profile, start a SHA-256 verified Mihomo executable, switch nodes and routing modes, and copy the local proxy address. It uses the same managed session as the Linux portable CLI.

## Download for Ubuntu 24.04 x86-64 / 下载试用包

Download the Linux x64 `.tar.gz` and its matching `.sha256` from the [0.3.4 preview](https://github.com/henwanla/CLAY/releases/tag/v0.3.4). In the download directory, run `sha256sum -c FILE.tar.gz.sha256` with the actual filename. Extract the verified archive, enter the extracted directory, and run `./start-clay`. Install the base window dependencies first:

~~~sh
sudo apt install python3-gi gir1.2-gtk-3.0 curl coreutils libstdc++6
~~~

The unsigned preview runs as your user on Ubuntu 24.04 x86-64. It needs no Swift installation and contains no Mihomo or profiles. The included KDE helper uses Ubuntu's `libkf5configcore5`; on distributions without it, use manual proxy or build the KF6 helper below. For newer branch builds, see the 30-day **CLAY-Linux-x64-preview** artifact in [Linux Actions](https://github.com/henwanla/CLAY/actions/workflows/portable-linux.yml?query=branch%3Amain).

从 [0.3.4 预览版](https://github.com/henwanla/CLAY/releases/tag/v0.3.4) 下载 Linux x64 的 tar.gz 与校验文件。在同一目录运行 `sha256sum -c FILE.tar.gz.sha256`（换成实际文件名），通过后解压，进入解压目录运行 `./start-clay`。这个未签名预览以 Ubuntu 24.04 x86-64 为测试基线，无需安装 Swift。请另行准备并校验 Mihomo。

## Build from source / 源码构建

To build from the repository root on Ubuntu 24.04:

```sh
sudo apt install python3-gi gir1.2-gtk-3.0 curl coreutils
swift build -c release --product clay-portable
/usr/bin/python3 Platforms/Linux/clay-desktop.py --cli .build/release/clay-portable
```

1. Pick a local profile or a downloaded subscription file and click **Load nodes**. The main window shows each node's name and protocol alongside its import number, so you can distinguish nodes with the same protocol. The tray keeps only the number. If you edit the file, load it again.
2. Choose the extracted Mihomo executable for your architecture and enter the expected SHA-256 of the executable. If the publisher supplies only an archive checksum, verify the archive first, then use `sha256sum` on the extracted executable.
3. Select a node and routing mode. For Rule mode, you can choose a file of CLAY PAC rules. **Start session** starts a manual proxy. A loopback address appears after Mihomo reports the requested settings. Enter it in individual applications as their HTTP or SOCKS5 proxy.
4. To change nodes or mode in the running session, select the new value and click **Apply**. A real change closes the connections tracked by Mihomo; applications may reconnect. Selecting the already active value leaves those connections alone. If the change is unconfirmed, **Refresh status** retries any pending connection cleanup before showing the route. Click **Stop** to end the session or **Quit CLAY** to stop and exit.

For subscriptions, install `python3-cryptography` and `libsecret-tools` and unlock your desktop Secret Service keyring (for example GNOME Keyring). While stopped, open **Subscriptions…**, enter a name and HTTPS address, then choose **Download and save** and **Use saved nodes**. **Refresh** updates the encrypted cache only after the new nodes pass validation; choose **Use saved nodes** again to apply it. Choose a local file and click **Load nodes** to switch back.

The downloader uses system certificate trust, allows only same-origin HTTPS redirects, and limits both download and decompression to 2 MiB. CLAY encrypts up to 12 saved feeds with AES-256-GCM; URLs, names and cached nodes are stored under the user's data directory, with the key in Secret Service. Downloads happen only when requested. A locked or missing keyring prevents saving. The selected copy goes to the local CLI over a private pipe. Mihomo still receives its temporary owner-only runtime config while it runs.

For the optional tray, install `gir1.2-ayatanaappindicator3-0.1` and use a desktop panel with StatusNotifierItem/AppIndicator support. When CLAY confirms a tray host, closing the window during a session keeps the proxy running. Open the tray menu to reopen CLAY, switch mode or node, refresh, stop, or quit. The menu shows up to 12 node numbers; **All nodes…** reopens the full picker. **Quit CLAY** in either place stops and exits. If the tray goes away while the window is hidden, CLAY brings the window back. Without the binding or a confirmed host, closing the window stops the session as before.

On GNOME, **Connect GNOME** starts the core and applies a PAC to apps that follow GNOME proxy settings. If a manual session is running, choose **Apply to GNOME** from the window or tray. The PAC keeps local destinations direct and sends other requests to Mihomo, where Rule, Global and Direct take effect. Switching modes or nodes does not replace the PAC URL. Manual usage remains available on other desktops or when system proxy settings are locked.

Use **Restore GNOME proxy** to restore the previous GNOME mode and script without stopping the core. Stop and Quit restore settings that CLAY still owns before closing the listener. If the process is terminated abruptly, reopen CLAY in the same desktop session to recover. If another app changes the settings, CLAY preserves the newer values it reads. If the script still points to CLAY but the mode or address no longer matches, remove CLAY's script address in the desktop's proxy settings and retry. The recovery snapshot is stored locally with owner-only permissions; it may contain the prior PAC URL and is removed after recovery. It isn't sent anywhere. TUN and login startup are outside this preview. The tray exports node numbers and confirmed modes to the local session bus; profile paths, engine logs and node credentials are not included.

On **Plasma 6**, install CMake, Qt Base and the KDE KConfig development package (for example `qt6-base-dev` and `libkf6config-dev` on suitable Debian-based systems), then build the settings helper once:

~~~sh
cmake -S Platforms/Linux/kde -B .build/kde -DCMAKE_BUILD_TYPE=Release
cmake --build .build/kde
install -m 755 .build/kde/clay-kde-settings "$(dirname "$(realpath .build/release/clay-portable)")/clay-kde-settings"
~~~

Use **Connect Plasma**, **Apply to Plasma**, or **Restore Plasma proxy** in the window or tray. CLAY temporarily changes only the user's proxy mode and script URL through KConfig. Existing proxy fields and bypass lists remain in place; whether an app uses them depends on its resolver. PAC applies to clients that read the Plasma settings, such as ones using libproxy with its KDE backend and PAC support. Some already-open apps may need to be reopened. If an app uses its own proxy settings, use the manual address. Plasma 5 and managed or nonstandard configurations are outside this preview.

## 中文说明

Linux 桌面预览可以读取本地节点配置、启动通过 SHA-256 校验的 Mihomo，并在会话中切换节点和路由模式。请在仓库根目录运行上面的安装、构建和启动命令。

1. 选择本地配置或已下载的订阅文件，点 **Load nodes**。主窗口显示节点名称、协议和导入编号，方便分辨同一协议下的多个节点。托盘只显示编号。修改文件后请重新加载。
2. 选择解压后的 Mihomo 可执行文件，填写该文件的预期 SHA-256。若上游只提供压缩包校验值，先验证压缩包，再计算解压后的文件哈希。
3. 选好节点和模式，按需为 Rule 模式添加 CLAY PAC 规则文件。**Start session** 启动手动代理，内核确认后会显示 HTTP／SOCKS5 本机地址，可在需要代理的应用中填写。实际切换会关闭内核跟踪的已有连接，重复选择当前项不会中断。切换未确认时，用 **Refresh status** 重试清理并读回状态。
4. 运行时可通过 **Apply** 切换，结果未确认时可用 **Refresh status** 重新核对。点击 **Stop** 停止代理，**Quit CLAY** 停止并退出。

订阅功能需要 `python3-cryptography`、`libsecret-tools` 以及已解锁的系统钥匙串（Secret Service，如 GNOME Keyring）。停止会话后打开 **Subscriptions…**，填写名称和 HTTPS 地址，点击 **Download and save** 后用 **Use saved nodes** 加载。**Refresh** 只有在新节点通过验证后才会替换缓存，刷新后须重新选择才会生效。需要切回本地配置时，选择文件并点击 **Load nodes**。

下载使用系统证书信任，只允许同源 HTTPS 跳转，线上及解压后的内容各不超过 2 MiB。最多保存 12 份订阅，名称、地址、节点等以 AES-256-GCM 加密写入当前用户的数据目录，密钥保存在 Secret Service。每次添加或刷新都由用户主动触发；钥匙串不可用时不能保存。选中的节点通过本机管道传给 CLI，Mihomo 运行期间仍需要一份仅当前用户可读的临时运行配置。

可选托盘：安装上面的 Ayatana 绑定，并使用支持 StatusNotifierItem／AppIndicator 的桌面面板。确认托盘可用后，运行中关闭窗口会保留会话。可从托盘打开窗口、切换节点和规则／全局／直连，或刷新、停止和退出。菜单显示最多 12 个节点编号，**All nodes…** 可打开完整列表。托盘消失时会重新显示窗口；绑定未安装或托盘未确认时，关闭窗口会停止代理并退出。

在 GNOME 中可用 **Connect GNOME** 启动并应用系统 PAC。手动会话已启动时，可从窗口或托盘选择 **Apply to GNOME**。遵循 GNOME 代理设置的应用会保留本地地址直连，其他流量交给内核的规则／全局／直连模式。切节点或模式不改变 PAC 地址。其他桌面或系统设置锁定时仍可手动接入。

**Restore GNOME proxy** 恢复原 GNOME 模式和脚本地址，同时保留内核。停止或退出会先恢复仍由 CLAY 管理的设置，再关监听。异常退出后，在同一桌面环境重新打开 CLAY 会尝试恢复。检测到外部新设置时会保留；若脚本仍指向 CLAY，但模式或地址已被改过，请在桌面的代理设置中移除 CLAY 脚本地址，再重试。恢复记录保存在当前用户专用目录，可能包含原 PAC 地址，恢复后删除，不会上传。暂不支持 TUN 和开机启动；托盘不展示节点名、服务器或凭据。

**Plasma 6** 可按上面的命令构建 KConfig 辅助程序，再使用 **Connect Plasma**、**Apply to Plasma** 或 **Restore Plasma proxy**。CLAY 只临时改代理模式和脚本地址，原有手动代理字段和例外列表仍保留。需要应用支持读取 Plasma 代理设置，例如使用带 KDE 后端和 PAC 支持的 libproxy；部分已打开的应用可能需要重启。使用独立代理设置的应用可填手动地址。Plasma 5 和受管理或非标准配置不在本次预览范围。

## Offline rule preview / 离线规则预览

In development builds, enable **Use rules file** while stopped, select a local file, then choose **Preview rules…**. Leave the target blank to verify the file or enter a domain, IP address, or full URL and click **Check**. The first matching rule wins. Match numbers count rules only; errors show the actual line in the file. The preview describes the selected file in Rule mode. Global and Direct ignore the file; system PAC can bypass the proxy for local requests before the engine sees them. CLAY never looks up the preview target, opens it, or saves it.

开发版在会话停止时勾选 **Use rules file**，选好文件后点 **Preview rules…**。留空可检查文件，填入域名、IP 或完整 URL 后可以看命中的第一条规则。命中编号跳过注释及空行，语法错误显示实际文件行号。结果对应规则模式；全局和直连模式不使用该文件，系统 PAC 也可能先让本地请求直连。CLAY 不查询、不打开，也不保存测试地址。

## Synthetic checks / 测试

The adapter check works on macOS or Linux. Ubuntu’s GTK check uses the real Linux CLI, a synthetic engine, private dconf storage, and a tray watcher and Secret Service on a private session bus. It verifies exported menu actions, independent system settings readback, restart recovery, background cleanup, and a cached subscription session. The download fixture makes no external requests.

The Plasma test uses native KConfig and Ubuntu’s libproxy KDE backend on an isolated configuration. It verifies actual PAC decisions, restoration of inherited and explicit settings, rejection of locked or ambiguous configurations, and tray controls. A Qt/KF5 build of the helper is used in this runner to check the same configuration format. A full Plasma session and browsers are outside the fixture.

```sh
python3 Platforms/Linux/smoke-desktop.py .build/release/clay-portable --adapter-only
sudo apt install gir1.2-ayatanaappindicator3-0.1 dbus-daemon xvfb xauth gsettings-desktop-schemas dconf-gsettings-backend dconf-service libglib2.0-bin python3-cryptography libsecret-tools gnome-keyring
bash Platforms/Linux/smoke-gnome.sh .build/release/clay-portable
```
