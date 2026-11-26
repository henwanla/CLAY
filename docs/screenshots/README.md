# CLAY screenshots / 界面截图

在 macOS 上从仓库根目录运行：

    bash scripts/render-readme-screenshots.sh

脚本用独立构建渲染应用实际的「概览」和「连接」内容区，只读取示例节点、保留域名和合成流量。无需启动已安装的 CLAY、读取窗口或连接网络。提交前打开生成的两张 PNG，检查字号、裁切和图中数据。常规 App 构建不包含截图入口。

Run the command above on macOS to render the app’s Overview and Connections panels. The renderer uses an isolated build with synthetic data and does not read live windows or connect to the network. Open both PNGs and check the formatting and demo data before committing.
