# 参与 CLAY / Contributing

欢迎反馈安装、节点导入、PAC、仪表和菜单栏问题。报告请带 CLAY 与 Mihomo 版本、macOS 版本、架构、复现步骤、实际结果及预期结果。请使用合成配置或脱敏后的诊断报告；不要附订阅 URL、节点凭据、原始配置、真实访问记录或能看到个人主机名的截图。

## 分支与提交

- `main` 保存通过验收的版本，发布标签从 `main` 的验证提交创建；`develop` 是日常集成分支。
- 从当前 `main` 切主题分支，PR 通常提交给 `develop`。PR 写明用户可见的变化、范围和验证结果。维护者验收后将对应版本的变更合入 `main`。
- 维护提交使用 `feat（0.3.0）：新增 PAC 规则预览`、`fix（0.3.0）：恢复代理设置失败时保留回环服务` 或 `upd（0.3.0）：补充公开安装说明` 这样的标题。请选择对应的版本和类型，用自己的 Git 身份提交。

维护者换机器或新克隆仓库时，请在本仓库的本地 Git 配置中设置 `user.name` 和 `user.email`。邮箱请从自己 GitHub 账号的 Emails 设置复制 GitHub 提供的 noreply 地址，避免将个人邮箱写入公开提交。提交前用 `git var GIT_AUTHOR_IDENT` 和 `git var GIT_COMMITTER_IDENT` 核对实际使用的身份；这些命令的输出请只在本机查看。

## 验证

需要 macOS、Swift 5.9+ 和 Python 3。在仓库根目录运行：

```sh
bash scripts/swift-local.sh build -c release
.build/release/CLAYCoreChecks
.build/release/CLAYCoreChecks --pac-fixture
python3 scripts/smoke-subscriptions.py .build/release/CLAYCoreChecks
```

测试默认使用静态和回环夹具。涉及系统 PAC 的自动检查使用合成网络设置；macOS 的授权提示、实际网络服务和浏览器行为需要另行手动验收。界面变更请附上用合成数据截取的图片或录屏。依赖许可和发行步骤见 [打包及发布](docs/RELEASING.md)。

## English

`main` holds reviewed releases; `develop` is the integration branch. Create a topic branch based on `main` and normally open a PR into `develop`. Describe the behavior change and the checks you ran. Use your own Git identity. The commands above build the app and run static and loopback checks on macOS. Live authorization prompts and desktop interaction require a separate manual test. Please use synthetic or redacted data in issues, PRs, and screenshots; never post subscription URLs, node credentials, or raw configurations.

On a new clone, set `user.name` and `user.email` in the repository's local Git configuration. Use the GitHub-provided noreply address from your account's email settings to keep your personal address out of public commits. Before committing, check the effective identity locally with `git var GIT_AUTHOR_IDENT` and `git var GIT_COMMITTER_IDENT`.
