# CLAY iOS 配置检查

这个预览应用把 CLAY 的节点解析器带到 iPhone 和 iPad。粘贴节点分享链接、Base64 链接列表、内联节点形式的 Clash/Mihomo YAML 或 JSON，或 V2Ray/Xray JSON 出站，即可看到可解析的节点数量、协议分布和问题类别。也可以用内置示例验证：结果应显示一个兼容的 VLESS 节点和一项不支持的协议。

检查在设备上进行，文本最多 2 MiB，结果只显示汇总。粘贴的内容不会写入应用文件；点「清除输入」会清空输入和结果。iOS 版本不下载订阅，不执行分流规则或提供器，不启动代理或 VPN，也不判断节点能否连通。界面随系统语言提供简体中文、英文和日文。

在 macOS 安装完整 Xcode 和 iOS Simulator SDK 后，可从仓库根目录构建：

```sh
xcodebuild -project Platforms/iOS/CLAY.xcodeproj -scheme CLAY \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

最低系统版本为 iOS/iPadOS 16。仓库附带 iOS Simulator 构建工作流；其构建产物用于开发验证，没有签名、真机安装或商店分发流程。
