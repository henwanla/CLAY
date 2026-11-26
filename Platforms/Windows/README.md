# CLAY Portable for Windows / Windows 便携命令行

Windows 10/11 runtime preview. Build with Swift for Windows and provide a native Mihomo executable and its expected SHA-256 from a trusted source. CLAY does not download the executable or import remote subscriptions on Windows.

这是 Windows 10/11 的运行预览。使用 Windows 版 Swift 编译，准备适用于本机处理器的 Mihomo 可执行文件，并从可信来源取得该文件的预期 SHA-256。CLAY 不会在 Windows 上下载内核或导入远程订阅。

```
swift build -c release --product clay-portable
$bin = Join-Path (swift build -c release --show-bin-path) 'clay-portable.exe'
& $bin inspect .\nodes.txt --numbered
& $bin mihomo-run .\nodes.txt 1 .\mihomo.exe '<64-digit SHA-256>' --mode rule --pac-rules .\rules.txt
```

The example runs node 1. The PAC rules file is optional; use it with `--mode rule`. The printed `proxy=127.0.0.1:PORT` address can be set as the HTTP proxy in an individual browser or app. To keep the port fixed, pass `--proxy-port PORT`. Press Ctrl+C to end the foreground session. Switch node or route mode by restarting with a new node number or `--mode` option.

示例运行第 1 个节点。PAC 规则文件可省略，使用时选 `--mode rule`。看到 `proxy=127.0.0.1:端口` 后，在需要代理的浏览器或应用中填入该地址。可用 `--proxy-port 端口` 固定端口。按 Ctrl+C 停止；更换节点或路由模式时，用新的节点编号或 `--mode` 参数重启命令。

Windows does not yet offer a GUI, interactive switching, or automatic system proxy settings. Config and generated state live in a private directory under the Windows local application data folder, accessible by default to the current user. CLAY stops the engine and removes the directory on normal termination. If Windows or the CLI is force-terminated before cleanup, the private directory can remain; remove only the stale `clay-win-*` directory after confirming the session has ended.

Windows 暂无图形界面、运行时切换或自动设置系统代理。配置和运行文件放在 Windows 本地应用数据目录下的私有文件夹，默认只允许当前用户访问。正常停止时会关闭内核并移除这个目录。若系统或命令行被强制终止，可能留下该目录；确认会话已结束后，再删除对应的残留 `clay-win-*` 目录。
