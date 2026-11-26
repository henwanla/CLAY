# CLAY Portable for Windows / Windows 便携命令行

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
