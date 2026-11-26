# CLAY 打包与发布 / Release process

在 Apple Silicon Mac 上从已通过验证的源码构建。公开版与本机预览版是两种包：公开版不分发 Mihomo。两者都应保留 CLAY 的 MIT 许可和 Yams/libyaml 的上游许可；本机预览包含独立的 Mihomo、GPL 许可证和固定版本源码入口。发布 GitHub Release 本身不会完成 Developer ID 签名、公证或桌面验收。

## 版本验证

1. 在 `develop` 验证变更；从用于发布的 `main` 提交再次确认构建与 CI，核对版本、`CHANGELOG.md` 和 README 的边界说明。版本标签由 `VERSION` 加上 `v` 得到；标记为预发布。更新现有版本时创建新标签并保留旧资产。
2. 按 [参与开发](https://github.com/henwanla/CLAY/blob/main/CONTRIBUTING.md) 运行核心和订阅检查。运行下列扩展检查时，使用已核验的官方 Mihomo / Xray 可执行文件和合成配置：

   ```sh
   bash scripts/smoke-workspace.sh /绝对路径/mihomo
   python3 scripts/smoke-loopback.py .build/release/clayctl /绝对路径/mihomo /绝对路径/xray
   ```

3. 按 [验收记录](验收记录.md) 跟踪程序和桌面验证。未操作过系统 PAC 授权弹窗、网络服务切换、菜单栏和图表时，把这些列为待人工验收。报告中只写实际验证结果。

## GitHub 安装包（无内核）

```sh
bash scripts/package-macos.sh --public
cd dist/release
version="$(cat ../../VERSION)"
shasum -a 256 -c "CLAY-$version-macos-arm64.zip.sha256"
unzip -l "CLAY-$version-macos-arm64.zip"
```

检查 ZIP 内有 CLAY.app 和许可材料，没有 Mihomo 可执行文件、Xray、真实配置、日志或本机凭据。解压到临时目录验证 App 的 `CFBundleShortVersionString`、arm64 架构和 `codesign --verify --strict`。归档 App 与相邻的 `.zip.sha256` 一同发布。

维护者确认远端标签指向通过验证的 `main` 提交后，在 [henwanla/CLAY](https://github.com/henwanla/CLAY) 将其发布为 GitHub 预发布。发布说明写清 Apple Silicon、macOS 13+ 构建目标、未公证、Mihomo 需要独立安装并校验，以及当前兼容范围。CI 只做验证，不创建标签或发布。

## Linux GitHub Actions 试用包 / Linux CI preview

Ubuntu 24.04 x86-64 工作流从 Swift 官网下载固定的 Swift 6.4.3。它先用官方 Swift 6.x 发布密钥验签并核对签名者指纹，再解包、检查版本和目标架构，然后静态链接 Swift 运行时并构建 KDE 辅助程序。本机复验时先准备同一工具链，再从干净检出的源码运行以下命令。CI 会解包检查 ELF 与本机库依赖，在隔离的桌面会话测试通过后才上传 Artifacts。压缩包记录完整源码提交，随附对应许可证及 SHA-256 校验文件。Mihomo 和用户配置不入包。

~~~sh
swift build -c release --static-swift-stdlib --product clay-portable
cmake -S Platforms/Linux/kde -B .build/kde -DCMAKE_BUILD_TYPE=Release
cmake --build .build/kde --parallel 2
strip --strip-debug .build/release/clay-portable .build/kde/clay-kde-settings
python3 scripts/package-linux.py .build/release/clay-portable .build/kde/clay-kde-settings dist/linux
~~~

The Ubuntu 24.04 x86-64 workflow verifies the official Swift 6.4.3 archive against the pinned Swift 6.x release signing key before extraction. It checks the compiler version and target, then packages the GTK app, the statically linked Swift CLI and the built KDE helper. It tests the extracted preview with system libraries and isolated desktop settings before uploading a 30-day Actions artifact. The preview is unsigned and does not publish to GitHub Releases. See the [Linux download guide](../Platforms/Linux/README.md#download-for-ubuntu-2404-x86-64--下载试用包).

## 本机预览（有独立内核）

验证 [Mihomo 官方资产](https://github.com/henwanla/CLAY/blob/main/README.md#为公开安装包准备-mihomo) 后，使用解压后的可执行文件和 [固定 tag 的许可](https://github.com/MetaCubeX/mihomo/blob/v1.19.34/LICENSE) 生成本机预览目录：

```sh
bash scripts/package-macos.sh /绝对路径/mihomo /绝对路径/Mihomo-LICENSE
```

本机目录提供 `dist/CLAY.app`、`dist/Dependencies/` 和 `dist/使用手册.md`。本机预览包也在 App 的资源目录放入同一份独立、带许可证的可执行文件。移动整个 App 后，未选其他内核时可直接使用，启动前仍会核对固定的 SHA-256。

## English

Build and verify on Apple Silicon. CI uses synthetic fixtures and checks the public package’s checksum, ad hoc signature, Apple Silicon executable, version, and license notices. It does not publish builds. Release the verified ZIP and SHA-256 file as a prerelease from the reviewed commit on the stable branch. The public ZIP requires a separately installed Mihomo; the local preview may contain the pinned, verified core and its upstream license. Do not mark authorization prompts, browser PAC behavior, or other desktop interaction as verified unless they were tested separately.
