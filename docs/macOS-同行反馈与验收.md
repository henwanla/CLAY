# macOS 同行反馈与验收

2026-11-27 通过 GitHub 公共 Issues 查询 V2rayU、Clash Verge Rev 和 Mihomo。优先核对正常安装后无法接管流量、会话断开或代理设置残留等问题。反馈是上游项目的复现线索，不能直接认定 CLAY 存在相同问题。

| 反馈 | CLAY 核对与处理 |
| --- | --- |
| [Clash Verge Rev #8598](https://github.com/clash-verge-rev/clash-verge-rev/issues/8598)：切换网络后系统代理未恢复 | CLAY 区分已写入 PAC 与当前网络确实使用 PAC。切网后新增「接入当前网络」：先恢复旧网络设置，再把同一监听接到新的主要网络；不在后台覆盖其他服务的设置。双网络模拟测试检查两边设置、原监听和退出恢复。该反馈同时涉及 TUN 和系统 DNS，两者不属于 CLAY macOS 的系统 PAC 路径。 |
| [Clash Verge Rev #8610](https://github.com/clash-verge-rev/clash-verge-rev/issues/8610)：换订阅后出现旧延时 | 探测结果归属实际节点列表及会话。订阅更新先保留运行中的节点；采用新列表时清空探测状态，晚到的结果无法写入。测试覆盖刷新成功、刷新失败、被取消的回调以及组成员同连接改名。 |
| [Clash Verge Rev #6342](https://github.com/clash-verge-rev/clash-verge-rev/issues/6342)：选中尚未测完的节点时崩溃 | 节点选择和测速使用独立任务。测试用延迟探测夹具，在批量测速期间切节点、切流量模式、停止会话和重新导入。 |
| [Clash Verge Rev #7967](https://github.com/clash-verge-rev/clash-verge-rev/issues/7967)：自动切换后连接停留在旧路径 | 自动切换沿用手动切换的内核确认和旧连接清理。双上游回环验证已有连接关闭，并验证新请求和分组出口使用已确认的节点。 |
| [V2rayU #1380](https://github.com/yanue/V2rayU/issues/1380)：更新失败后丢失组内节点 | CLAY 只在新内容解析成功并完成加密目录的原子保存后采用更新；失败刷新不会清除上一份可用节点和分组。桌面导入原有的资源上限仍适用。 |
| [V2rayU #1656](https://github.com/yanue/V2rayU/issues/1656)：缺 PAC 文件却进入 PAC 模式 | CLAY 在内存生成脚本，先确认回环 PAC 监听已经创建，再申请系统接入。合成后端覆盖下载、授权拒绝、延迟生效以及恢复时监听保留。 |
| [V2rayU #1359](https://github.com/yanue/V2rayU/issues/1359)：希望延时反映真实代理 | CLAY 用内核的节点 URL 探测，经指定节点请求 204 地址；显示 HTTP 请求耗时。它不是 ICMP 延时，也不能单独判断服务故障。 |
| [Mihomo #3355](https://github.com/MetaCubeX/mihomo/issues/3355)：macOS 27 有进程归属识别失败的报告 | 在受支持的 macOS 测试机回环验证应用包内辅助进程的实际路由。系统没有提供进程归属的连接仍走普通规则。无需手动读取本机真实应用连接，也不把应用规则当作断网保护。 |

界面参考 [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) 的概览、代理分组和连接页组织。CLAY 采用独立流量卡、强调当前模式的分段按钮、按组浏览的节点卡片、延时徽标及可取消的批量进度，不复制对方的图像或应用代码。截图来自 CLAY 自己的 SwiftUI 视图，数据均为合成。

尚需人工验证：真实 Wi-Fi／有线切换的配置授权和传播时序，Chrome 对系统 PAC 的采用，以及 macOS 27 的进程识别。测试不触碰用户当前网络配置，不用真实订阅、应用进程或节点密码。
