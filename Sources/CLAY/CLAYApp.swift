import AppKit
import CLAYCore
import SwiftUI

@main struct CLAYApp: App {
    @NSApplicationDelegateAdaptor(ExitHandler.self) private var exitHandler
    private var model: Workspace { exitHandler.model }
    fileprivate static let dashboardID = "dashboard"

    var body: some Scene {
        WindowGroup("CLAY", id: Self.dashboardID, for: String.self) { _ in
            Dashboard(model: model, pac: model.pac).frame(minWidth: 740, minHeight: 550)
        } defaultValue: {
            Self.dashboardID
        }
        .defaultSize(width: 970, height: 650)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            StatusMenu(model: model, pac: model.pac)
        } label: {
            StatusIndicator(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor final class ExitHandler: NSObject, NSApplicationDelegate {
    let model = Workspace()
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) { model.monitorHealth() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true
        Task {
            let stopped = await model.shutdown()
            if !stopped { quitting = false }
            sender.reply(toApplicationShouldTerminate: stopped)
            if !stopped {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "系统 PAC 尚未恢复"
                alert.informativeText = "CLAY 会保留代理进程和本机 PAC 地址。请从 PAC 页面恢复系统设置后再退出。"
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
        return .terminateLater
    }
}

private struct StatusIndicator: View {
    @ObservedObject var model: Workspace
    var body: some View {
        Image(systemName: model.busy && !model.running ? "cube.transparent" : model.running ? "cube.fill" : "cube")
            .accessibilityLabel(Text("CLAY · \(model.menuStatus)"))
    }
}

private struct StatusMenu: View {
    @ObservedObject var model: Workspace
    @ObservedObject var pac: PACControl
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("CLAY · \(model.menuStatus)")
        if model.running || pac.needsRecovery { Text(pac.modeLabel) }
        Menu("流量模式：\(model.routingMode.label)") {
            ForEach(CoreRoutingMode.allCases) { mode in
                Button { model.selectRoutingMode(mode) } label: {
                    if mode == model.routingMode { Label(mode.label, systemImage: "checkmark") }
                    else { Text(mode.label) }
                }
            }
        }.disabled(model.busy)
        if !model.nodes.isEmpty {
            Menu("节点：\(model.chosen?.name ?? "未选")") {
                ForEach(model.nodes) { node in
                    Button { model.select(node) } label: {
                        if node.id == model.active { Label(node.name, systemImage: "checkmark") }
                        else { Text(node.name) }
                    }.disabled(node.id == model.active)
                }
            }.disabled(model.busy)
        }
        if let address = model.proxyAddress {
            Button("复制代理地址") { model.copy(address) }
        }
        if let url = pac.localURL { Button("复制 PAC 地址") { model.copy(url.absoluteString) } }
        if pac.hasLiveOwnership || pac.needsRecovery {
            Button("恢复原网络代理设置") { pac.restoreSystem() }.disabled(pac.busy)
        }
        Divider()
        Button("打开 CLAY") {
            openWindow(id: CLAYApp.dashboardID, value: CLAYApp.dashboardID)
            if #available(macOS 14.0, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
        }
        Button(model.running ? "停止代理" : "启动代理") { model.toggleProxy() }.disabled(!model.canToggleProxy)
        Divider()
        Button("退出 CLAY") { NSApp.terminate(nil) }
    }
}

private enum Page: String, CaseIterable, Identifiable {
    case overview = "概览", connections = "连接", pac = "PAC 规则", nodes = "节点", subscriptions = "订阅", diagnostics = "诊断", settings = "设置"
    var id: Self { self }
    var icon: String { switch self { case .overview: return "square.grid.2"; case .connections: return "arrow.left.arrow.right"; case .pac: return "arrow.triangle.branch"; case .nodes: return "point.3.connected.trianglepath.dotted"; case .subscriptions: return "link"; case .diagnostics: return "waveform.path.ecg"; case .settings: return "gearshape" } }
}

private struct Dashboard: View {
    @ObservedObject var model: Workspace
    @ObservedObject var pac: PACControl
    @State private var page: Page? = .overview
    @State private var input = ""
    @State private var subscriptionName = ""
    @State private var subscriptionURL = ""
    @State private var nodeSearch = ""
    private let clay = Color(red: 0.86, green: 0.40, blue: 0.23)

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Image(systemName: "cube.fill").font(.title2).foregroundStyle(clay)
                    Text("CLAY").font(.system(size: 25, weight: .bold, design: .rounded)).tracking(2)
                }.padding(.leading, 13).padding(.top, 12)
                List(selection: $page) {
                    ForEach(Page.allCases) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                }.listStyle(.sidebar)
                Label(model.running ? "本机代理运行中" : "本机代理已停止", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(model.running ? Color.green : Color.secondary).padding(13)
            }.navigationSplitViewColumnWidth(min: 157, ideal: 186, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text((page ?? .overview).rawValue).font(.largeTitle.bold()); Spacer(); controls }
                    Text(model.status).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("session-status")
                    switch page ?? .overview {
                    case .overview: overview
                    case .connections: ConnectionDashboard(model: model)
                    case .pac: PACDashboard(model: model, control: pac)
                    case .nodes: nodes
                    case .subscriptions: subscriptions
                    case .diagnostics: diagnostics
                    case .settings: settings
                    }
                }.padding(27).frame(maxWidth: 1050, alignment: .topLeading).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.tint(clay)
            .sheet(isPresented: $model.presentImport, onDismiss: { input = "" }) { importSheet }
            .sheet(isPresented: $model.presentSubscription, onDismiss: { subscriptionURL = ""; subscriptionName = "" }) { subscriptionSheet }
    }
    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            if model.busy { ProgressView().controlSize(.small) }
            Button(model.running ? "停止" : "启动") { model.toggleProxy() }
                .buttonStyle(.borderedProminent).disabled(!model.canToggleProxy)
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            TrafficDashboard(model: model)
            panel("流量模式", symbol: "arrow.triangle.branch") {
                Picker("流量模式", selection: Binding(get: { model.routingMode }, set: model.selectRoutingMode)) {
                    ForEach(CoreRoutingMode.allCases) { mode in Text(mode.label).tag(mode) }
                }.pickerStyle(.segmented).labelsHidden().disabled(model.busy)
                Text(routingExplanation).font(.callout).foregroundStyle(.secondary)
                if model.routingMode == .rule && model.runningRules.map({ $0 != pac.policy }) == true {
                    Text("规则有未应用的改动。重启内核后用于手动接入的流量；PAC 仍按自己的发布状态更新。")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            panel("当前节点", symbol: "arrow.triangle.branch") {
                HStack {
                    Text(model.chosen?.name ?? "尚未选择节点").font(.headline).lineLimit(1)
                    Spacer()
                    Button(pac.modeLabel) { page = .pac }
                }
                if let n = model.chosen { Text("\(n.protocolName.uppercased()) · \(n.transport) · \(n.security)").foregroundStyle(.secondary) }
                if let proxy = model.proxyAddress {
                    HStack { Text(proxy).monospaced().textSelection(.enabled); Button("复制") { model.copy(proxy) } }
                    Text("HTTP 和 SOCKS5 共用这个端口。需要按规则分流时，可在「PAC 规则」生成本机地址或应用到 macOS。")
                        .font(.callout).foregroundStyle(.secondary)
                } else { Text("导入节点并启动后，这里会显示独立的回环代理地址。").foregroundStyle(.secondary) }
            }
            if model.nodes.isEmpty {
                HStack {
                    Button("导入 V2Ray 节点") { model.presentImport = true }
                    Button("添加订阅…") { page = .subscriptions; model.presentSubscription = true }.disabled(model.fetchingSubscription)
                }
            }
        }
    }
    private var routingExplanation: String {
        switch model.routingMode {
        case .rule: return "进入本机代理的流量按「PAC 规则」中的规则及未命中行为分流。"
        case .global: return "进入本机代理的流量全部走当前节点。"
        case .direct: return "进入本机代理的流量直接连接目标，不走当前节点。"
        }
    }
    private var nodes: some View {
        let query = nodeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleNodes = model.nodes.filter { node in
            query.isEmpty || [node.name, node.protocolName, node.transport, node.security].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return VStack(alignment: .leading, spacing: 13) {
            HStack { Button("粘贴导入") { model.presentImport = true }.disabled(model.running || model.busy)
                Button("选择文件…") { _ = model.importFile() }.disabled(model.running || model.busy)
                if model.canUseManual { Button("使用手动列表") { model.chooseSource(nil) } }
                Spacer(); Text("\(model.nodes.count) 个节点").foregroundStyle(.secondary) }
            if model.sourceChangePending { stagedNotice }
            if model.nodes.isEmpty {
                Text("支持 VMess、VLESS、Shadowsocks 和 Trojan 分享链接，也可以导入兼容的 V2Ray/Xray 或 Clash 配置及订阅。").foregroundStyle(.secondary)
                Button("管理订阅") { page = .subscriptions }
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索节点名称或协议", text: $nodeSearch).textFieldStyle(.roundedBorder)
                    if !nodeSearch.isEmpty { Button("清除") { nodeSearch = "" } }
                }
                if visibleNodes.isEmpty { Text("没有匹配的节点。").foregroundStyle(.secondary) }
            }
            ForEach(visibleNodes) { n in
                HStack(spacing: 13) {
                    Image(systemName: model.active == n.id ? "largecircle.fill.circle" : "circle").foregroundStyle(model.active == n.id ? clay : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(n.name).font(.headline).lineLimit(1)
                        Text("\(n.protocolName.uppercased()) · \(n.transport) · \(n.security)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let probe = model.probes[n.id] { Text(probe.text).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Button("选择") { model.select(n) }.disabled(model.busy || model.active == n.id)
                }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
            importReport
        }
    }
    private var subscriptions: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button("添加订阅…") { model.presentSubscription = true }.disabled(model.fetchingSubscription)
                if model.fetchingSubscription { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("添加服务商提供的订阅 URL，可随时刷新。每次成功下载的节点保存在此 Mac，再次打开 CLAY 时也能使用。")
                .foregroundStyle(.secondary)
            if !model.subscriptionMessage.isEmpty { Text(model.subscriptionMessage).font(.callout) }
            if model.sourceChangePending { stagedNotice }
            ForEach(model.subscriptions) { subscription in
                HStack(spacing: 12) {
                    Image(systemName: model.selectedSubscription == subscription.id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(model.selectedSubscription == subscription.id ? clay : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.name).font(.headline).lineLimit(1)
                        Text("\(subscription.count) 个节点 · 更新于 \(subscription.updated.formatted(.dateTime.month().day().hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("使用") { model.chooseSource(subscription.id) }
                        .disabled(model.selectedSubscription == subscription.id || subscription.count == 0)
                    Button("刷新") { model.refreshSubscription(subscription.id) }.disabled(model.fetchingSubscription)
                    Button("移除", role: .destructive) { model.removeSubscription(subscription.id) }.disabled(model.fetchingSubscription)
                }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private var stagedNotice: some View {
        Label("当前代理继续使用原节点列表；停止并再次启动后使用最新列表。", systemImage: "clock.arrow.circlepath")
            .font(.callout).foregroundStyle(.secondary)
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 16) {
            panel("节点连通性", symbol: "waveform.path.ecg") {
                Text("探测会通过选中的节点请求 gstatic.com 的 204 检测地址。延迟表示该请求用时，无法单凭它判断代理服务故障的具体原因。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("探测当前节点") { if let n = model.chosen { model.measure([n]) } }.disabled(!model.running || model.busy)
                    Button("批量探测") { model.measure(model.nodes, compare: true) }.disabled(!model.running || model.busy || model.nodes.isEmpty)
                    Spacer()
                    Button("复制脱敏报告") { model.copySummary() }.disabled(model.nodes.isEmpty)
                }
                Text("连续完成两次批量探测后，会标出恢复连通、变为不可用和延迟变化。对比保留在本次会话。")
                    .font(.caption).foregroundStyle(.secondary)
                if let last = model.lastProbe { Text(last, style: .time).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(model.nodes.enumerated()), id: \.element.id) { index, node in
                    if let probe = model.probes[node.id] {
                        HStack {
                            Text("节点 \(index + 1) · \(node.name)").lineLimit(1); Spacer()
                            if let before = model.previousBatch[node.id], let after = model.latestBatch[node.id] {
                                Text(after.change(from: before)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(probe.text).monospacedDigit()
                        }
                    }
                }
                Text("分享内容只包含节点编号、协议、传输、探测状态和迁移问题种类；不含节点名字或凭据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            importReport
        }
    }
    private var settings: some View {
        panel("代理内核", symbol: "cpu") {
            Text(model.engine?.lastPathComponent ?? "未选择可执行文件").font(.headline)
            Button("选择 Mihomo…") { model.chooseEngine() }.disabled(model.running || model.busy)
            Text("CLAY 单独启动 Mihomo，只监听 127.0.0.1。手动导入仅在本次使用中保留；订阅会保存在此 Mac。")
                .foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var importReport: some View {
        if model.hasImported {
            panel("最近一次迁移", symbol: "square.and.arrow.down") {
                if model.issues.isEmpty { Text("没有发现需要跳过的项目。") }
                ForEach(model.issues.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { e in
                    Text("\(model.issues[e, default: 0]) 项 · \(Workspace.issue(e))").foregroundStyle(.secondary)
                }
            }
        }
    }
    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入节点").font(.title2.bold())
            Text("粘贴分享链接，每行一个，或粘贴包含节点的 JSON / YAML。订阅网址请到「订阅」页添加。")
                .foregroundStyle(.secondary)
            TextEditor(text: $input).font(.body.monospaced()).frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)))
                .accessibilityLabel("节点分享链接或 JSON")
            if model.hasImported && !model.issues.isEmpty { Text(model.status).foregroundStyle(.secondary) }
            HStack {
                Button("选择文件…") { if model.importFile() { finishImport() } }
                Spacer(); Button("取消") { model.presentImport = false }.keyboardShortcut(.cancelAction)
                Button("导入") { if model.applyImport(input) { finishImport() } }.keyboardShortcut(.defaultAction).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(23).frame(width: 530)
    }
    private func finishImport() { model.presentImport = false; page = .nodes }
    private var subscriptionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加订阅").font(.title2.bold())
            Text("输入服务商提供的订阅 URL。CLAY 会在本机保存链接和最后一次成功导入的内容。")
                .foregroundStyle(.secondary)
            TextField("名称（选填）", text: $subscriptionName)
            SecureField("订阅 URL", text: $subscriptionURL)
            if !model.subscriptionMessage.isEmpty { Text(model.subscriptionMessage).font(.callout) }
            HStack {
                if model.fetchingSubscription { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.fetchingSubscription ? "关闭" : "取消") { model.presentSubscription = false }.keyboardShortcut(.cancelAction)
                Button("添加并使用") { model.addSubscription(name: subscriptionName, input: subscriptionURL) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.fetchingSubscription || subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(23).frame(width: 530)
    }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).lineLimit(1)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.43), in: RoundedRectangle(cornerRadius: 13))
    }
    private func panel<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
    }
}
