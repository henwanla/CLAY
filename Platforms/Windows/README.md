# CLAY for Windows / Windows 桌面与命令行

## Desktop preview / 桌面预览

On x64 Windows, build the portable CLI with Swift and the window with the .NET 10 SDK. Run the following in PowerShell from the repository root. The desktop app can also use `clay-portable.exe` copied next to it; the Swift and .NET Desktop runtimes must be available on the host.

在 Windows x64 上先用 Swift 编译便携 CLI，再用 .NET 10 SDK 编译桌面端。在仓库根目录用 PowerShell 执行如下命令。也可以把 `clay-portable.exe` 放在桌面 App 旁边；系统需要可用的 Swift 和 .NET Desktop 运行时。

```powershell
swift build -c release --product clay-portable
$bin = Join-Path (swift build -c release --show-bin-path) 'clay-portable.exe'
dotnet run -c Release --project Platforms/Windows/Desktop -- --cli $bin
```

Load a local profile, choose the extracted Mihomo executable, enter its verified SHA-256, and choose a node and mode. An optional rules file is used in Rule mode. Start, then enter the displayed loopback address in the client app. Closing the window keeps the session in the system tray. Open the tray menu to switch nodes or mode, stop the proxy, or quit CLAY. The app uses the Windows display language for Simplified Chinese, English, and Japanese.

加载本地节点文件，选择已解压的 Mihomo，填写核验过的 SHA-256，再选择节点、模式，按需导入规则文件。启动后在需要代理的应用里手动填写回环地址。关闭窗口后会话留在 Windows 托盘；托盘菜单可切节点、切模式、停止代理或退出 CLAY。界面随系统语言显示简体中文、英文或日文。

This preview does not configure the Windows system proxy, register for login startup, or download subscriptions. It does not save profile paths, node credentials, or traffic history. CI builds the native Windows app and runs its redirected session bridge using a synthetic local controller. Visual layout and Explorer tray behavior need a physical Windows desktop check.

桌面预览不会设置系统代理、注册开机启动或下载在线订阅，不保存配置路径、节点凭据和流量历史。CI 构建原生 Windows App，用合成回环控制器验收窗口所用的会话桥接；Explorer 托盘外观和实际桌面交互需另行验收。

The [Windows GitHub Actions workflow](https://github.com/henwanla/CLAY/actions/workflows/portable-windows.yml) packages successful branch builds as the **CLAY-Windows-x64-preview** artifact for 14 days. Extract the ZIP, compare its SHA-256 against the accompanying file, and follow `START-HERE.txt`. The package is unsigned and requires the .NET 10 Desktop Runtime, Swift runtime and a separately verified Mihomo. It is a preview artifact, separate from the public macOS Release.

[Windows 构建记录](https://github.com/henwanla/CLAY/actions/workflows/portable-windows.yml)会为通过验证的分支提供 **CLAY-Windows-x64-preview**，保留 14 天。核对 ZIP 的 SHA-256 后按 `START-HERE.txt` 解压试用。预览包未签名，需准备 .NET 10 Desktop Runtime、Swift 运行时和已核验的 Mihomo。正式 Release 仍是 macOS 版。

## Portable CLI / 便携命令行

Windows 10/11 runtime preview. Build with Swift for Windows and provide a native Mihomo executable and its expected SHA-256 from a trusted source. CLAY does not download the executable or import remote subscriptions on Windows.

这是 Windows 10/11 的运行预览。使用 Windows 版 Swift 编译，准备适用于本机处理器的 Mihomo 可执行文件，并从可信来源取得该文件的预期 SHA-256。CLAY 不会在 Windows 上下载内核或导入远程订阅。

```
swift build -c release --product clay-portable
$bin = Join-Path (swift build -c release --show-bin-path) 'clay-portable.exe'
& $bin inspect .\nodes.txt --numbered
& $bin mihomo-run .\nodes.txt 1 .\mihomo.exe '<64-digit SHA-256>' --all-nodes --interactive --mode rule --pac-rules .\rules.txt
```

The example starts with node 1. The PAC rules file is optional; it is used in Rule mode. Enter the printed `proxy=127.0.0.1:PORT` address as the proxy in a client app. To keep the port fixed across sessions, pass `--proxy-port PORT`. While the session is running, enter `status`, `node 2`, or `mode rule|global|direct`. Node and mode changes are checked against Mihomo's reported state and do not restart the listener. Use `quit` or Ctrl+C to stop. Without `--all-nodes`, the session only loads the requested node.

示例从第 1 个节点启动。PAC 规则文件可省略，由规则模式使用。看到 `proxy=127.0.0.1:端口` 后，在需要代理的应用里填写该地址。可用 `--proxy-port 端口` 让不同会话使用同一端口。会话中输入 `status`、`node 2` 或 `mode rule|global|direct`；内核读回成功才确认切换，端口不变。输入 `quit` 或按 Ctrl+C 停止。不加 `--all-nodes` 时只加载启动时选择的节点。

This is a foreground CLI and does not change Windows system proxy settings. Config and generated state live in a private directory under the Windows local application data folder, accessible by default to the current user. The controller key stays in the session and config file. CLAY stops the engine and removes the directory on normal termination. If Windows or the CLI is force-terminated before cleanup, the private directory can remain; remove only the stale `clay-win-*` directory after confirming the session has ended.

这是前台命令行预览，不会修改 Windows 系统代理。配置和运行文件放在 Windows 本地应用数据目录下的私有文件夹，默认只允许当前用户访问。控制密钥留在会话和配置文件中。正常停止会关闭内核并移除目录。若系统或命令行被强制终止，可能留下目录；确认会话已结束后，再删除对应的残留 `clay-win-*` 目录。
