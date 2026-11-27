import AppKit
import CLAYCore
import SwiftUI

#if !CLAY_DOCUMENTATION
@main
#endif
struct CLAYApp: App {
    @NSApplicationDelegateAdaptor(ExitHandler.self) private var exitHandler
    @StateObject private var navigation = DashboardNavigation()
    private var model: Workspace { exitHandler.model }
    fileprivate static let dashboardID = "dashboard"

    var body: some Scene {
        WindowGroup("CLAY", id: Self.dashboardID, for: String.self) { _ in
            Dashboard(model: model, pac: model.pac, navigation: navigation).frame(minWidth: 740, minHeight: 550)
        } defaultValue: {
            Self.dashboardID
        }
        .defaultSize(width: 970, height: 650)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            StatusMenu(model: model, pac: model.pac, navigation: navigation)
        } label: {
            StatusIndicator(model: model, pac: model.pac)
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
    @ObservedObject var pac: PACControl
    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(Text("CLAY · \(model.menuStatus)"))
    }

    private var symbol: String {
        if pac.needsRecovery || pac.messageIsError { return "exclamationmark.triangle.fill" }
        if pac.busy { return "cube.transparent" }
        if model.running {
            if pac.systemPACIsEffective { return "checkmark.circle.fill" }
            return pac.systemService == nil ? "cube.fill" : "exclamationmark.circle"
        }
        return model.busy ? "cube.transparent" : "cube"
    }
}

private struct StatusMenu: View {
    @ObservedObject var model: Workspace
    @ObservedObject var pac: PACControl
    @ObservedObject var navigation: DashboardNavigation
    @Environment(\.openWindow) private var openWindow

    private var quickNodes: [NodeProfile] {
        let nodes = model.nodes.prefix(12)
        if let current = model.chosen, !nodes.contains(where: { $0.id == current.id }) {
            return Array(nodes.prefix(11)) + [current]
        }
        return Array(nodes)
    }

    var body: some View {
        Text("CLAY · \(model.menuStatus)")
        if pac.systemService == nil, pac.localURL != nil, !pac.needsRecovery { Text("本机 PAC 已启用") }
        if pac.messageIsError { Text(pac.message) }
        if pac.hasLiveOwnership || pac.needsRecovery {
            Button("恢复原网络代理设置") { pac.restoreSystem() }.disabled(pac.busy || model.busy)
        }
        if pac.messageIsError || pac.needsRecovery || (pac.systemService != nil && !pac.systemPACIsEffective) {
            Button("查看 PAC 设置…") { showDashboard(.pac) }
        }
        Divider()
        if pac.systemService == nil || pac.needsRecovery || !model.running {
            Button("连接 macOS") { model.connectSystem() }.disabled(!model.canConnectSystem)
        }
        if model.running {
            Button("停止代理") { model.stop() }.disabled(model.busy || pac.busy)
        } else {
            Button("仅启动本机代理") { model.start() }.disabled(!model.canStartManual)
            if let issue = model.engineIssue { Text(issue) }
            if model.engine == nil {
                if model.offersBundledEngine {
                    Button("使用随附 Mihomo") { model.useBundledEngine() }.disabled(!model.canChangeEngine)
                }
                Button("设置 Mihomo 内核…") { showDashboard(.settings) }
            }
            if model.nodes.isEmpty {
                Button("导入节点…") { showDashboard(.nodes); model.presentImport = true }.disabled(model.busy)
                Button("添加订阅…") { showDashboard(.subscriptions); model.presentSubscription = true }
                    .disabled(model.fetchingSubscription)
            }
        }
        Divider()
        Menu("流量模式：\(model.routingConfirmed ? model.routingMode.label : "未确认")") {
            ForEach(CoreRoutingMode.allCases) { mode in
                Button { model.selectRoutingMode(mode) } label: {
                    if model.routingConfirmed && mode == model.routingMode { Label(mode.label, systemImage: "checkmark") }
                    else { Text(mode.label) }
                }
            }
        }.disabled(model.busy)
        if !model.nodes.isEmpty {
            Menu("节点：\(model.routingConfirmed ? model.chosen.map(nodeMenuTitle) ?? "未选" : "未确认")") {
                ForEach(quickNodes) { node in
                    Button { model.select(node) } label: {
                        if model.routingConfirmed && node.id == model.active { Label(nodeMenuTitle(node), systemImage: "checkmark") }
                        else { Text(nodeMenuTitle(node)) }
                    }.disabled(model.busy || (model.routingConfirmed && node.id == model.active))
                }
                Divider()
                Button("查看全部 \(model.nodes.count) 个节点…") { showDashboard(.nodes) }
            }
        }
        if let address = model.proxyAddress {
            Button("复制代理地址") { model.copy(address) }
        }
        if let url = pac.localURL { Button("复制 PAC 地址") { model.copy(url.absoluteString) } }
        Divider()
        Button("打开 CLAY") { showDashboard() }
        Button("退出 CLAY") { NSApp.terminate(nil) }
    }

    private func nodeMenuTitle(_ node: NodeProfile) -> String {
        guard let number = model.nodeNumber(node.id) else { return "未选" }
        return "#\(number) · \(node.protocolDisplayName)"
    }

    private func showDashboard(_ page: Page? = nil) {
        if let page { navigation.page = page }
        openWindow(id: CLAYApp.dashboardID, value: CLAYApp.dashboardID)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }
}

private enum Page: String, CaseIterable, Identifiable {
    case overview = "概览", connections = "连接", pac = "PAC 规则", nodes = "节点", subscriptions = "订阅", diagnostics = "诊断", settings = "设置"
    var id: Self { self }
    var icon: String { switch self { case .overview: return "square.grid.2"; case .connections: return "arrow.left.arrow.right"; case .pac: return "arrow.triangle.branch"; case .nodes: return "point.3.connected.trianglepath.dotted"; case .subscriptions: return "link"; case .diagnostics: return "waveform.path.ecg"; case .settings: return "gearshape" } }
    var subtitle: String {
        switch self {
        case .overview: return "查看流量、连接状态和当前节点"
        case .connections: return "查看经过代理的连接、命中规则和流量"
        case .pac: return "配置系统代理、分流与应用规则"
        case .nodes: return "管理分组、测试延时和切换节点"
        case .subscriptions: return "管理节点来源与订阅更新"
        case .diagnostics: return "查看测速结果和迁移记录"
        case .settings: return "管理本机代理内核"
        }
    }
}

private final class DashboardNavigation: ObservableObject {
    @Published var page: Page? = .overview
}

#if CLAY_DOCUMENTATION
@MainActor func documentationDashboard(model: Workspace, section: String) -> some View {
    let navigation = DashboardNavigation()
    navigation.page = ["connections": Page.connections, "nodes": .nodes, "routing": .pac][section] ?? .overview
    return Dashboard(model: model, pac: model.pac, navigation: navigation).detailPane
}
#endif

private struct Dashboard: View {
    @ObservedObject var model: Workspace
    @ObservedObject var pac: PACControl
    @ObservedObject var navigation: DashboardNavigation
    private var page: Page? {
        get { navigation.page }
        nonmutating set { navigation.page = newValue }
    }
    @State private var input = ""
    @State private var subscriptionName = ""
    @State private var subscriptionURL = ""
    @State private var nodeSearch = ""
    @State private var groupDraft: GroupDraft?
    private let clay = clayAccent

    private struct GroupDraft: Identifiable {
        let id = UUID()
        let original: UUID?
        var name: String
        var members: Set<UUID>
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Image(systemName: "cube.fill").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 34, height: 34)
                        .background(clay.gradient, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CLAY").font(.system(size: 20, weight: .bold, design: .rounded)).tracking(1.6)
                        Text("代理工作台").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.leading, 14).padding(.top, 16)
                List(selection: $navigation.page) {
                    ForEach(Page.allCases) { item in Label(item.rawValue, systemImage: item.icon).padding(.vertical, 4).tag(item) }
                }.listStyle(.sidebar)
                Label(model.menuStatus, systemImage: connectionSymbol)
                    .font(.caption).foregroundStyle(connectionColor).padding(13)
            }.navigationSplitViewColumnWidth(min: 157, ideal: 186, max: 240)
        } detail: { detailPane }
            .tint(clay)
            .sheet(isPresented: $model.presentImport, onDismiss: { input = "" }) { importSheet }
            .sheet(isPresented: $model.presentSubscription, onDismiss: { subscriptionURL = ""; subscriptionName = "" }) { subscriptionSheet }
            .sheet(item: $groupDraft) { _ in groupEditor }
    }

    fileprivate var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text((page ?? .overview).rawValue).font(.system(size: 32, weight: .bold))
                        Text((page ?? .overview).subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    controls
                }
                HStack {
                    Label(model.menuStatus, systemImage: connectionSymbol).font(.callout.weight(.semibold))
                        .foregroundStyle(connectionColor).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(connectionColor.opacity(0.1), in: Capsule())
                    if model.status != model.menuStatus {
                        Text(model.status).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("session-status")
                    }
                }
                if page != .pac { pacNotice }
                if !model.running { setupActions }
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
        }.background {
            Color(nsColor: .windowBackgroundColor).overlay(alignment: .top) {
                LinearGradient(colors: [clay.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 280).allowsHitTesting(false)
            }
        }.tint(clay)
    }
    private var connectionSymbol: String {
        if pac.needsRecovery || pac.messageIsError { return "exclamationmark.triangle.fill" }
        if model.running, pac.systemPACIsEffective { return "checkmark.circle.fill" }
        if model.running, pac.systemService != nil { return "exclamationmark.circle" }
        return model.running ? "circle.fill" : "circle"
    }

    private var connectionColor: Color {
        if pac.needsRecovery || pac.messageIsError || (pac.systemService != nil && !pac.systemPACIsEffective && !pac.busy) { return .orange }
        return model.running && pac.systemPACIsEffective ? .green : .secondary
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if model.busy || pac.busy { ProgressView().controlSize(.small) }
            if model.running {
                Button { model.stop() } label: { Label("停止代理", systemImage: "stop.circle") }
                    .controlSize(.large).disabled(model.busy || pac.busy)
            } else {
                Button("仅启动本机代理") { model.start() }
                    .help("启动回环代理端口供应用手动连接；不修改 macOS 网络设置。")
                    .disabled(!model.canStartManual)
            }
            if pac.systemService == nil || pac.needsRecovery || !model.running {
                Button { model.connectSystem() } label: { Label("连接 macOS", systemImage: "bolt.horizontal.circle.fill") }
                    .buttonStyle(ClayActionButtonStyle())
                    .controlSize(.large)
                    .help("让使用 macOS 系统代理的应用跟随当前流量模式。")
                    .disabled(!model.canConnectSystem)
            }
        }
    }

    @ViewBuilder private var pacNotice: some View {
        if pac.needsRecovery || pac.messageIsError {
            VStack(alignment: .leading, spacing: 7) {
                if pac.needsRecovery {
                    Label(pac.recoveryService.map { "「\($0.name)」的系统代理设置待恢复。" } ?? "系统代理设置待恢复。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                }
                if pac.messageIsError {
                    Text(pac.message).font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    if pac.needsRecovery {
                        Button("恢复原网络代理设置") { pac.restoreSystem() }.disabled(model.busy || pac.busy)
                    }
                    Button("查看 PAC 设置") { page = .pac }
                }
            }
        }
    }

    @ViewBuilder private var setupActions: some View {
        if model.engine == nil || model.nodes.isEmpty {
            panel("连接前的准备", symbol: "checklist") {
                if model.engine == nil {
                    Text(model.engineIssue ?? "缺少 Mihomo 内核。请先选择一个可信的可执行文件。")
                        .font(.callout).foregroundStyle(.secondary)
                    engineActions
                }
                if model.nodes.isEmpty {
                    Text("当前没有节点。请添加服务商的订阅，或导入已有节点。").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("添加订阅…") { page = .subscriptions; model.presentSubscription = true }
                            .disabled(model.fetchingSubscription)
                        Button("导入节点…") { model.presentImport = true }.disabled(model.busy)
                    }
                }
            }
        }
    }
    private var engineActions: some View {
        HStack {
            if model.offersBundledEngine {
                Button("使用随附 Mihomo") { model.useBundledEngine() }
            }
            Button("选择 Mihomo…") { model.chooseEngine() }
        }.disabled(!model.canChangeEngine)
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            TrafficDashboard(model: model)
            panel("流量模式", symbol: "arrow.triangle.branch") {
                RouteModePicker(model: model)
                Text(routingExplanation).font(.callout).foregroundStyle(.secondary)
                if model.routingConfirmed && model.routingMode == .rule && model.hasUnappliedRoutes {
                    Text("规则有未应用的改动。重启代理后会载入新规则；自定义 PAC 仍可从 PAC 页面单独更新。")
                        .font(.callout).foregroundStyle(.orange)
                }
                if pac.systemService != nil && !pac.followsRoutingMode {
                    Label("自定义 PAC 可能先直连部分请求。需要系统流量跟随此处的模式时，请在 PAC 页面点「跟随流量模式」。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            panel("当前节点", symbol: "arrow.triangle.branch") {
                HStack {
                    Text(model.routingConfirmed ? model.chosen?.name ?? "尚未选择节点" : "节点未确认").font(.headline).lineLimit(1)
                    Spacer()
                    Button(pac.modeLabel) { page = .pac }
                }
                if model.routingConfirmed, let n = model.chosen { Text("\(n.protocolDisplayName) · \(n.transport) · \(n.security)").foregroundStyle(.secondary) }
                if let proxy = model.proxyAddress {
                    HStack { Text(proxy).monospaced().textSelection(.enabled); Button("复制") { model.copy(proxy) } }
                    Text("HTTP 和 SOCKS5 共用这个端口，可填入需要手动配置的应用。")
                        .font(.callout).foregroundStyle(.secondary)
                    if pac.systemService == nil && !pac.needsRecovery {
                        Text("macOS 尚未接入。点「连接 macOS」后，使用系统代理的应用会跟随当前流量模式。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else { Text("代理启动后，这里会显示本机代理地址。").foregroundStyle(.secondary) }
            }
        }
    }
    private var routingExplanation: String {
        guard model.routingConfirmed else { return model.status }
        switch model.routingMode {
        case .rule: return "进入本机代理的流量按应用、域名、网段及默认策略分流。"
        case .global: return "进入本机代理的流量全部走当前节点。"
        case .direct: return "进入本机代理的流量直接连接目标，不走当前节点。"
        }
    }
    private var nodes: some View {
        let query = nodeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleNodes = model.orderedNodes.filter { node in
            query.isEmpty || [node.name, node.protocolName, node.protocolDisplayName, node.transport, node.security].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return LazyVStack(alignment: .leading, spacing: 13) {
            HStack { Button("粘贴导入") { model.presentImport = true }.disabled(model.running || model.busy)
                Button("选择文件…") { _ = model.importFile() }.disabled(model.running || model.busy)
                if model.canUseManual { Button("使用手动列表") { model.chooseSource(nil) } }
                Spacer(); Text("\(model.nodes.count) 个节点").foregroundStyle(.secondary) }
            if model.sourceChangePending { stagedNotice }
            if model.nodes.isEmpty {
                Text("支持 VMess、VLESS、Shadowsocks、Trojan 和 Hysteria2 分享链接，也可以导入兼容的 V2Ray/Xray 或 Clash 配置及订阅。").foregroundStyle(.secondary)
                Button("管理订阅") { page = .subscriptions }
            } else {
                nodeGroupControls
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索节点名称或协议", text: $nodeSearch).textFieldStyle(.roundedBorder)
                    if !nodeSearch.isEmpty { Button("清除") { nodeSearch = "" } }
                }
                if visibleNodes.isEmpty { Text("没有匹配的节点。").foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 294), spacing: 12)], spacing: 12) {
                ForEach(visibleNodes) { node in nodeCard(node) }
            }
            importReport
        }
    }

    private func nodeCard(_ node: NodeProfile) -> some View {
        let current = model.routingConfirmed && model.active == node.id
        let isGroupSelection = model.currentGroup.map { model.groupNode($0)?.id == node.id }
        let probe = model.probes[node.id]
        let latencyTint: Color = probe?.milliseconds.map { $0 < 150 ? .green : $0 < 450 ? .orange : .red }
            ?? (probe == nil ? .secondary : .red)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: current ? "checkmark.circle.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.callout.weight(.semibold)).foregroundStyle(current ? clay : .secondary)
                Text(node.name).font(.headline).lineLimit(1).help(node.name)
                Spacer(minLength: 2)
                Text(probe?.text ?? "未测速").font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(latencyTint).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(latencyTint.opacity(0.09), in: Capsule())
            }
            HStack(spacing: 5) {
                if let number = model.nodeNumber(node.id) { Text("#\(number)").monospacedDigit() }
                Text(node.protocolDisplayName)
                Text("· \(node.transport) · \(node.security)").lineLimit(1)
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { model.measure([node]) } label: { Label("测速", systemImage: "timer") }.disabled(!model.canMeasure)
                Spacer()
                if current && isGroupSelection != false { Label("当前节点", systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(clay) }
                else { Button("选择") { model.select(node) }.buttonStyle(ClayActionButtonStyle(secondary: true)).disabled(model.busy) }
            }
        }.clayCard(selected: current)
    }
    private var nodeGroupControls: some View {
        panel("节点分组与测速", symbol: "point.3.connected.trianglepath.dotted") {
            HStack {
                Picker("范围", selection: Binding(get: { model.selectedGroup }, set: model.chooseGroup)) {
                    Text("全部节点").tag(UUID?.none)
                    ForEach(model.groups) { group in Text(group.name).lineLimit(1).tag(Optional(group.id)) }
                }.frame(maxWidth: 230)
                Button("新建分组…") { groupDraft = GroupDraft(original: nil, name: "", members: []) }
                if let group = model.currentGroup {
                    Button("编辑…") {
                        groupDraft = GroupDraft(original: group.id, name: group.name, members: Set(model.members(of: group).map(\.id)))
                    }
                }
                Spacer()
                Picker("排序", selection: $model.nodeOrder) {
                    ForEach(Workspace.NodeOrder.allCases) { Text($0.rawValue).tag($0) }
                }.fixedSize()
            }
            HStack {
                Button { model.measure(model.scopedNodes, compare: true) } label: {
                    Label("批量测速 · \(model.scopedNodes.count)", systemImage: "gauge.with.dots.needle.67percent")
                }.buttonStyle(ClayActionButtonStyle())
                    .disabled(!model.canMeasure || model.scopedNodes.isEmpty)
                if let progress = model.probeProgress {
                    Button("停止测速") { model.cancelProbe() }
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .labelsHidden().frame(maxWidth: 100)
                    Text("\(progress.automatic ? "自动测速" : "测速") \(progress.completed)/\(progress.total)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if !model.probeMessage.isEmpty {
                    Text(model.probeMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("自动测速与切换", isOn: Binding(get: { model.automaticEnabled }, set: model.setAutomatic))
                    .toggleStyle(ClaySwitchStyle()).fixedSize()
            }
            Text(model.running ? "测速通过节点请求 gstatic.com；批量检测仅覆盖当前范围，不受搜索筛选影响。" :
                    "启动本机代理后可测速，无需接管 macOS 系统代理。")
                .font(.caption).foregroundStyle(.secondary)
            if model.automaticEnabled {
                Text("每 5 分钟检查当前范围。节点不可用或有明显更快的选择时才切换；直连模式暂停自动检测。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.groupMessage.isEmpty { Text(model.groupMessage).font(.caption).foregroundStyle(.orange) }
        }
    }

    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(groupDraft?.original == nil ? "新建节点分组" : "编辑节点分组").font(.title2.bold())
            TextField("组名", text: Binding(get: { groupDraft?.name ?? "" }, set: { groupDraft?.name = $0 }))
            Text("节点可同时属于多个组。订阅分组保存在本机，手动导入的分组在本次打开期间有效。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(model.nodes.enumerated()), id: \.element.id) { i, node in
                        Toggle("#\(i + 1) · \(node.name)", isOn: Binding(
                            get: { groupDraft?.members.contains(node.id) ?? false },
                            set: { checked in
                                if checked { groupDraft?.members.insert(node.id) }
                                else { groupDraft?.members.remove(node.id) }
                            }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.frame(height: 210)
            if !model.groupMessage.isEmpty { Text(model.groupMessage).foregroundStyle(.orange) }
            HStack {
                if let id = groupDraft?.original {
                    Button("删除分组", role: .destructive) {
                        model.removeGroup(id)
                        if model.groupMessage.isEmpty { groupDraft = nil }
                    }
                }
                Spacer()
                Button("取消") { groupDraft = nil }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let draft = groupDraft, model.saveGroup(id: draft.original, name: draft.name, nodeIDs: draft.members) { groupDraft = nil }
                }.keyboardShortcut(.defaultAction).disabled(groupDraft.map {
                    $0.members.isEmpty || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } ?? true)
            }
        }.padding(23).frame(width: 560)
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
                    Button("到节点页测速") { page = .nodes }
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
            if model.usesBundledEngine {
                Text("随附 Mihomo").font(.headline)
            } else if let engine = model.engine {
                Text("外部内核 · \(engine.lastPathComponent)").font(.headline)
            } else {
                Text("未选择可执行文件").font(.headline)
            }
            if let issue = model.engineIssue { Text(issue).font(.callout).foregroundStyle(.orange) }
            engineActions
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
        }.clayCard()
    }
}

extension View {
    func clayCard(selected: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        return self.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay { shape.strokeBorder(selected ? clayAccent.opacity(0.55) : Color.primary.opacity(0.09)) }
    }
}

private let clayAccent = Color(red: 0.72, green: 0.29, blue: 0.16)

struct ClayActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var size
    var secondary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.semibold))
            .foregroundStyle(secondary ? Color.primary : .white)
            .padding(.horizontal, size == .large ? 13 : 10).padding(.vertical, size == .large ? 8 : 6)
            .background(secondary ? Color.primary.opacity(0.06) : clayAccent, in: RoundedRectangle(cornerRadius: 7))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.76 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct ClaySwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                configuration.label.font(.callout.weight(.medium))
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(configuration.isOn ? clayAccent : .secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
    }
}

struct RouteModePicker: View {
    @ObservedObject var model: Workspace

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CoreRoutingMode.allCases) { mode in
                let selected = model.routingConfirmed && model.routingMode == mode
                Button { model.selectRoutingMode(mode) } label: {
                    Label(mode.label, systemImage: symbol(mode)).font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .foregroundStyle(selected ? clayAccent : Color.secondary)
                        .background(selected ? clayAccent.opacity(0.13) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.disabled(model.busy)
    }

    private func symbol(_ mode: CoreRoutingMode) -> String {
        switch mode {
        case .rule: return "arrow.triangle.branch"
        case .global: return "globe"
        case .direct: return "arrow.right"
        }
    }
}
