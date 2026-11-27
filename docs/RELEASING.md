# CLAY 打包与发布 / Release process

桌面公开包面向 Apple Silicon、Windows x64 和 Ubuntu 24.04 x86-64，不分发 Mihomo。各包保留 CLAY 的 MIT 许可和 Yams/libyaml 的上游许可。macOS 包单独携带已固定校验的大陆 IP 快照及其归属和许可文件。本机 macOS 试用包可内置独立的 Mihomo，须保留 GPL 许可证和固定版本的源码入口。GitHub Release 不替代操作系统签名、公证或真实桌面验收。

## 版本验证

1. 在 `develop` 验证变更；从用于发布的 `main` 提交再次确认构建与 CI，核对版本、`CHANGELOG.md` 和 README 的边界说明。版本标签由 `VERSION` 加上 `v` 得到；标记为预发布。更新现有版本时创建新标签并保留旧资产。
2. 按 [参与开发](https://github.com/henwanla/CLAY/blob/main/CONTRIBUTING.md) 运行核心和订阅检查。运行下列扩展检查时，使用已核验的官方 Mihomo / Xray 可执行文件和合成配置：

   ```sh
   bash scripts/smoke-workspace.sh /绝对路径/mihomo
   python3 scripts/smoke-loopback.py .build/release/clayctl /绝对路径/mihomo /绝对路径/xray
   ```

3. 按 [验收记录](验收记录.md) 跟踪程序和桌面验证。未操作过系统 PAC 授权弹窗、网络服务切换、菜单栏和图表时，把这些列为待人工验收。报告中只写实际验证结果。

## 桌面预发布 / Desktop prerelease

1. 确认 `main` 的三个桌面工作流已对同一个待发布提交通过。下载这三个具体运行的 Actions 产物：**CLAY-macOS-arm64-preview**、**CLAY-Windows-x64-preview**、**CLAY-Linux-x64-preview**。每个只取包和同名 SHA-256 文件；核对版本和架构，Windows 与 Linux 另核对包内 `START-HERE.txt` 的提交。保留运行编号作为来源记录。
2. 核对三个压缩包的 SHA-256、文件清单、许可和根目录结构。不得含 Mihomo、真实配置、日志、本机路径或凭据；macOS 增查解包后的签名及 Info.plist。发布 CI 实际验证的同一批文件。
3. 新建 `v<VERSION>` 标签，核对远端标签指向已验证的 `main` 提交。创建 GitHub 预发布草稿，上传三个包及各自的校验文件。回读草稿的资产清单与摘要，通过才公开；同时检查最终发布为不可变及旧发布仍在。变更已发资产时创建新版本。
4. 写明系统和依赖：macOS 需 Apple Silicon，App 只有临时签名；Windows 需 .NET 10 Desktop Runtime 和 Swift 运行时，Linux 则无需安装 Swift；三个包均需单独准备已校验的 Mihomo。Windows 和 Linux 是未签名预览；Android 和 iOS 仅在其发行验收完成后单独发布。

## Windows 与 Linux · 官方内核指纹

开发版按**已解压可执行文件**的 SHA-256 识别固定版本。只支持表中两个 amd64-compatible 构建，不按文件名授权。校验记录来自 [MetaCubeX 官方 v1.19.34 Release](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34)。维护变更时，先核对官方 Release API 的压缩包 digest，再计算指定成员的摘要与检查架构，两者都要复验。

| 官方资产 | 压缩包 SHA-256 | 解压后的 SHA-256 |
| --- | --- | --- |
| `mihomo-linux-amd64-compatible-v1.19.34.gz` | `2763f5b414527f7baf6dc57e3f82f3ab561eedf34bfd7c2f2cde1f7e592efe06` | `5b6644c487e5dffae86b0e0e9bb5cec445579a3a9d03977c09576fee2aeefc01` |
| `mihomo-windows-amd64-compatible-v1.19.34.zip` → `mihomo-windows-amd64-compatible.exe` | `cd6738d4648cc1a5f48049a1343b697ab510889d648f045c5c780fc1ab443a79` | `5a0231811a80b27477ebdee15684b41946d01afbd2114534e9a4b256125ca147` |

GitHub CI 先验证官方压缩包摘要，再在 runner 临时目录解压并核对可执行文件。用已核验的官方内核和合成回环节点复验识别、会话启停、换节点、流量计数和失败不回落直连。执行仅限隔离测试；发行包不含 Mihomo 或测试压缩包。

## 本机构建 macOS 公开包（无内核）

```sh
bash scripts/package-macos.sh --public
cd dist/release
version="$(cat ../../VERSION)"
shasum -a 256 -c "CLAY-$version-macos-arm64.zip.sha256"
unzip -l "CLAY-$version-macos-arm64.zip"
```

检查 ZIP 内有 CLAY.app 和许可材料，没有 Mihomo 可执行文件、Xray、真实配置、日志或本机凭据。解压到临时目录验证 App 的 `CFBundleShortVersionString`、arm64 架构和 `codesign --verify --strict`。归档 App 与相邻的 `.zip.sha256` 一同发布。

此命令供本机复验。发布时使用对应 `main` 运行上传且已验证的压缩包；CI 不创建标签或发布。

## Linux GitHub Actions 试用包 / Linux CI preview

Ubuntu 24.04 x86-64 工作流从 Swift 官网下载固定的 Swift 6.4.3。它先用官方 Swift 6.x 发布密钥验签并核对签名者指纹，再解包、检查版本和目标架构，然后静态链接 Swift 运行时并构建 KDE 辅助程序。本机复验时先准备同一工具链，再从干净检出的源码运行以下命令。CI 会解包检查 ELF 与本机库依赖，在隔离的桌面会话测试通过后才上传 Artifacts。压缩包记录完整源码提交，随附对应许可证及 SHA-256 校验文件。Mihomo 和用户配置不入包。

~~~sh
swift build -c release --static-swift-stdlib --product clay-portable
cmake -S Platforms/Linux/kde -B .build/kde -DCMAKE_BUILD_TYPE=Release
cmake --build .build/kde --parallel 2
strip --strip-debug .build/release/clay-portable .build/kde/clay-kde-settings
python3 scripts/package-linux.py .build/release/clay-portable .build/kde/clay-kde-settings dist/linux
~~~

The Ubuntu 24.04 x86-64 workflow verifies the official Swift 6.4.3 archive against the pinned Swift 6.x release signing key before extraction. It checks the compiler version and target, then packages the GTK app, the statically linked Swift CLI and the built KDE helper. It tests the extracted preview with system libraries and isolated desktop settings before uploading a 30-day Actions artifact. The preview is unsigned. Maintainers can publish the exact verified artifact's inner files with a tagged release. See the [Linux download guide](../Platforms/Linux/README.md#download-for-ubuntu-2404-x86-64--下载试用包).

## 本机预览（有独立内核）

验证 [Mihomo 官方资产](https://github.com/henwanla/CLAY/blob/main/README.md#为公开安装包准备-mihomo) 后，使用解压后的可执行文件和 [固定 tag 的许可](https://github.com/MetaCubeX/mihomo/blob/v1.19.34/LICENSE) 生成本机预览目录：

```sh
bash scripts/package-macos.sh /绝对路径/mihomo /绝对路径/Mihomo-LICENSE
```

本机目录提供 `dist/CLAY.app`、`dist/Dependencies/` 和 `dist/使用手册.md`。本机预览包也在 App 的资源目录放入同一份独立、带许可证的可执行文件。移动整个 App 后，未选其他内核时可直接使用，启动前仍会核对固定的 SHA-256。

## English

Use the three successful desktop Actions runs from the same `main` commit. Keep the run IDs, verify each inner archive against its companion hash, check the contents, and publish those exact files. Point a new version tag at the verified commit. Upload all six assets to an unpublished prerelease draft, check the recorded digests, publish, and verify immutability. Use the local Apple Silicon build for reproduction; it is not the artifact produced by CI. Public packages require a separately installed Mihomo. Do not claim authorization prompts, browser PAC behavior, or native tray interaction as verified unless they were tested separately.
