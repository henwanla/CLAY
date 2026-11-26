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
3. Select a node and routing mode. For Rule mode, you can choose a file of CLAY PAC rules. Start the session. A loopback address appears after Mihomo reports the requested settings. Enter the address in individual applications as their HTTP or SOCKS5 proxy.
4. To change nodes or mode in the running session, select the new value and click **Apply**. If a change cannot be confirmed, click **Refresh status** to check the current state. Click **Stop** or close the window to end the session.

Rule, Global and Direct control traffic sent to CLAY’s local listener. Linux desktop proxy settings, TUN, tray integration, login startup and remote subscription refresh are outside this preview. Paths and hashes are not saved between launches. The UI uses short-lived private file copies for inspection and launch, and does not show engine logs or controller credentials.

## 中文说明

Linux 桌面预览可以读取本地节点配置、启动通过 SHA-256 校验的 Mihomo，并在会话中切换节点和路由模式。请在仓库根目录运行上面的安装、构建和启动命令。

1. 选择本地配置或已下载的订阅文件，点 **Load nodes**。编号和命令行导入顺序一致，列表只显示协议、传输类型和安全模式。修改文件后请重新加载。
2. 选择解压后的 Mihomo 可执行文件，填写该文件的预期 SHA-256。若上游只提供压缩包校验值，先验证压缩包，再计算解压后的文件哈希。
3. 选好节点和模式，按需为 Rule 模式添加 CLAY PAC 规则文件。启动后，只有内核确认了节点和模式才会显示本地地址。请在需要使用代理的应用中自行填写该 HTTP 或 SOCKS5 地址。
4. 运行时可通过 **Apply** 切换，结果未确认时可用 **Refresh status** 重新核对。点击 **Stop** 或关闭窗口会结束会话。

这是应用级代理预览，暂不支持系统代理、TUN、托盘、开机启动或在线刷新订阅。退出后不记忆选择；导入和启动过程中仅短暂保留私有文件副本。

## Synthetic checks / 测试

The adapter check works on macOS or Linux; Ubuntu’s headless GTK check uses the real Linux CLI with a synthetic engine and no external network access.

```sh
python3 Platforms/Linux/smoke-desktop.py .build/release/clay-portable --adapter-only
sudo apt install xvfb xauth
xvfb-run -a /usr/bin/python3 Platforms/Linux/smoke-desktop.py .build/release/clay-portable
```
