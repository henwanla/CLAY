# CLAY screenshots / 界面截图

在 macOS 上从仓库根目录运行：

    bash scripts/render-readme-screenshots.sh

截图生成后会清除 EXIF、时间和文本等附加信息，CI 会检查。

The renderer strips extra PNG metadata. CI checks the published files.

脚本用独立构建渲染应用的「概览」「连接」「节点」和「PAC 规则」内容区，只使用示例节点、保留域名、虚构应用和合成流量、延时。无需启动已安装的 CLAY、读取窗口或连接网络。提交前检查生成的 PNG 的字号、裁切和图中数据。常规 App 构建不包含截图入口。

Run the command above on macOS to render the app’s Overview and Connections panels. The renderer uses an isolated build with synthetic data and does not read live windows or connect to the network. Open both PNGs and check the formatting and demo data before committing.
