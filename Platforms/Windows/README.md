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

Choose **Connect Windows** to start the session and temporarily apply CLAY's PAC to the current user's default Windows connection. If already running in manual mode, choose **Use Windows proxy** in the window or tray. Apps that follow Windows proxy settings will send non-local requests to Mihomo; locally addressed requests bypass the proxy. Rule, Global and Direct still belong to the running session and can be switched without changing the PAC URL. Apps with their own proxy configuration may need the manual address.

选择 **连接 Windows** 会启动会话，并为当前用户的默认网络临时应用 CLAY 的 PAC。已启动手动代理时，可从窗口或托盘选择 **应用到 Windows**。遵循系统代理的应用会把非本地请求交给 Mihomo；回环、本地域名和私有字面 IP 仍直连。规则／全局／直连可以在线切换，无须写入新的 PAC 地址。使用独立代理配置的应用仍可手动接入。

**Restore Windows proxy** restores the prior settings and leaves the manual listener running. Stop and Quit restore the settings before closing the session. If CLAY is terminated abruptly, reopen it to recover. If Windows settings were changed separately, CLAY preserves those edits. If the current setup script still points to CLAY but the settings no longer match, remove CLAY’s script address in Windows Proxy settings and retry restoration or stop. The prior settings are encrypted locally with Windows DPAPI. CLAY does not remember local profile paths or keep traffic history.

**恢复 Windows 代理设置** 会恢复原设置，保留手动代理端口。停止和退出会先恢复设置，再关闭会话。异常退出后可重新打开 CLAY 恢复；其他应用或用户后来修改的设置会保留。若当前脚本仍指向 CLAY，但其他设置已改变，请在 Windows「代理」里移除 CLAY 的脚本地址，再重试恢复或停止。原设置用 Windows DPAPI 加密保存在本机；CLAY 不记住本地配置文件路径，也不保存流量历史。

CI tests the native Windows PAC and restoration in the runner’s disposable user profile, including the native PAC evaluator, encrypted recovery, and the session bridge with a synthetic local controller. Explorer tray appearance, real browser traffic and settings managed by an organization need separate validation. This preview does not provide TUN or login startup.

CI 在临时 Windows 用户配置中验收系统 PAC、原生 PAC 决策、加密恢复与合成会话桥接。Explorer 托盘外观、真实浏览器流量和组织管理的代理策略需另行验收。此预览不提供 TUN 或开机启动。

The [Windows GitHub Actions workflow](https://github.com/henwanla/CLAY/actions/workflows/portable-windows.yml) packages successful branch builds as the **CLAY-Windows-x64-preview** artifact for 14 days. Extract the ZIP, compare its SHA-256 against the accompanying file, and follow `START-HERE.txt`. The package is unsigned and requires the .NET 10 Desktop Runtime, Swift runtime and a separately verified Mihomo. It is a preview artifact, separate from the public macOS Release.

[Windows 构建记录](https://github.com/henwanla/CLAY/actions/workflows/portable-windows.yml)会为通过验证的分支提供 **CLAY-Windows-x64-preview**，保留 14 天。核对 ZIP 的 SHA-256 后按 `START-HERE.txt` 解压试用。预览包未签名，需准备 .NET 10 Desktop Runtime、Swift 运行时和已核验的 Mihomo。正式 Release 仍是 macOS 版。

## Subscriptions / 订阅管理

With the proxy stopped, open **Subscriptions…**, enter a name and HTTPS address, and choose **Download and save**. Pick a saved feed and choose **Use saved nodes** to load its cache for the next session. Refresh only replaces the saved copy; use the refreshed nodes explicitly to switch snapshots. A failed download or import leaves the last working cache available. **Load nodes…** switches back to a local profile. Removing the current feed also clears its selected snapshot.

停止代理后，打开「订阅管理…」，输入名称和 HTTPS 地址，点击「下载并保存」。在列表选择订阅后点「使用缓存节点」，下次会话就用这份节点。刷新只更新已保存的缓存；要换成新缓存，再点一次「使用缓存节点」。下载或解析失败仍可使用上次缓存。「加载节点…」可切回本地文件。移除当前订阅也会清掉已选择的快照。

CLAY uses Windows TLS trust, follows redirects only within the same HTTPS origin and accepts at most 2 MiB before and after decompression. It downloads only on request; the connection to the subscription server does not use the Windows system proxy. The name, URL, and nodes of up to 12 feeds are encrypted with the current Windows user's DPAPI in local app data. A profile goes to the CLI over a private pipe instead of a separate profile file. The engine still uses a per-session configuration in its current-user-only runtime directory; normal stop removes it.

CLAY 使用 Windows 的 TLS 信任，只允许同源 HTTPS 跳转，下载正文和解压后正文均限制在 2 MiB。只在手动下载或刷新时联网，订阅请求不使用 Windows 系统代理。最多保存 12 份订阅，名称、地址和节点均通过当前 Windows 用户的 DPAPI 加密保存在本地应用数据目录中。订阅正文通过私有进程管道交给 CLI；内核仍使用当前用户私有运行目录中的会话配置，正常停止会清理。

Native Windows CI tests downloaded-body limits and redirects with synthetic responses. It uses real DPAPI and the portable CLI to verify failed-refresh recovery, unreadable and copied records, and actual loopback traffic from a cached-node session. It does not contact real subscription providers or exercise the visible Windows desktop.

Windows 原生 CI 使用合成响应测试下载大小和跳转，再用实际 DPAPI 和 CLI 验证坏缓存、刷新留旧、节点切换与从缓存发起的回环流量。测试不访问真实订阅服务，也不操作实际 Windows 桌面。

## Portable CLI / 便携命令行

Windows 10/11 runtime preview. Build with Swift for Windows and provide a native Mihomo executable and its expected SHA-256 from a trusted source. The CLI does not download the executable or fetch remote subscriptions itself.

这是 Windows 10/11 的运行预览。使用 Windows 版 Swift 编译，准备适用于本机处理器的 Mihomo 可执行文件，并从可信来源取得该文件的预期 SHA-256。CLI 本身不会下载内核或拉取订阅。

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
