import AppKit
import CLAYCore
import SwiftUI

struct PACDashboard: View {
    @ObservedObject var model: Workspace
    @ObservedObject var control: PACControl
    @State private var preview = ""
    @State private var kind: PACRule.Kind = .domainSuffix
    @State private var matchValue = ""
    @State private var decision: PACDecision = .proxy
    @State private var editing: UUID?
    @State private var formError = ""
    @State private var showImport = false
    @State private var importText = ""
    @State private var importError = ""
    @State private var showApplications = false
    @State private var runningApps: [CoreAppRoute] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            routing
            runtime
            policy
            rules
        }
        #if !CLAY_DOCUMENTATION
        .onAppear { control.refreshServices() }
        #endif
        .sheet(isPresented: $showImport, onDismiss: { importText = ""; importError = "" }) { importSheet }
        .sheet(isPresented: $showApplications) { applicationSheet }
    }

    private var routing: some View {
        card("流量路由", icon: "point.topleft.down.to.point.bottomright.curvepath") {
            RouteModePicker(model: model)
            if model.hasUnappliedRoutes {
                Label("规则已保存，重新连接代理后生效。", systemImage: "arrow.clockwise.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack(alignment: .center, spacing: 16) {
                Picker("代理流量走", selection: $model.routingOptions.proxyGroup) {
                    Text("当前节点").tag(UUID?.none)
                    ForEach(model.groups) { group in
                        Text(group.name).tag(Optional(group.id)).disabled(model.members(of: group).isEmpty)
                    }
                    if let id = model.routingOptions.proxyGroup, !model.groups.contains(where: { $0.id == id }) {
                        Text("分组不可用").tag(Optional(id))
                    }
                }.frame(maxWidth: 300)
                if let group = model.groups.first(where: { $0.id == model.routingOptions.proxyGroup }), let node = model.groupNode(group) {
                    Text("经 \(node.name)").lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("绕开中国大陆", isOn: $model.routingOptions.bypassMainland).toggleStyle(ClaySwitchStyle())
            }
            Text("规则模式下，可让走代理的域名及默认流量进入指定组；大陆选项将 .cn 和命中随附大陆网段的目标设为直连。全局模式使用当前节点。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Label("应用规则", systemImage: "macwindow").font(.subheadline.weight(.semibold))
                Spacer()
                Button("添加运行中的应用…") { openApplicationPicker() }
            }
            ForEach(model.routingOptions.applications) { app in
                HStack {
                    Label(app.name, systemImage: "app.dashed").lineLimit(1)
                    Spacer()
                    Picker("去向", selection: Binding(get: {
                        model.routingOptions.applications.first { $0.id == app.id }?.target ?? app.target
                    }, set: { value in
                        if let index = model.routingOptions.applications.firstIndex(where: { $0.id == app.id }) {
                            model.routingOptions.applications[index].target = value
                        }
                    })) { routeTargets(app.target) }.labelsHidden().fixedSize()
                    Button(role: .destructive) { model.routingOptions.applications.removeAll { $0.id == app.id } } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless).accessibilityLabel("删除\(app.name)规则")
                }.padding(9).background(.background.opacity(0.66), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("应用规则仅在规则模式下匹配通过 CLAY 的连接，优先于域名和网段规则；回环保护仍优先。建议用「跟随流量模式」系统代理。忽略系统代理或无法识别来源进程的请求不会命中应用规则。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func routeTargets(_ selected: CoreRouteTarget) -> some View {
        Text("始终走当前节点").tag(CoreRouteTarget.selected)
        Text("直连").tag(CoreRouteTarget.direct)
        ForEach(model.groups) { group in
            Text(group.name).tag(CoreRouteTarget.group(group.id)).disabled(model.members(of: group).isEmpty)
        }
        if case .group(let id) = selected, !model.groups.contains(where: { $0.id == id }) {
            Text("分组不可用 · 使用当前节点").tag(selected)
        }
    }

    private func openApplicationPicker() {
        let existing = Set(model.routingOptions.applications.map(\.path))
        var seen: Set<String> = []
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = app.bundleURL, let name = app.localizedName,
                  let path = CoreAppRoute.canonicalPath(bundle) else { return nil }
            let row = CoreAppRoute(name: name, path: path, includesBundleHelpers: true, target: .selected)
            return row.isValid && !existing.contains(path) && seen.insert(path).inserted ? row : nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        showApplications = true
    }

    private var applicationSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择运行中的应用").font(.title2.bold())
            Text("选择后默认将该应用及安装包内的辅助进程设为走当前节点，可以再改成分组或直连。")
                .font(.callout).foregroundStyle(.secondary)
            if runningApps.isEmpty { Text("没有可添加的应用。打开目标应用后再试。").foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(runningApps) { app in
                        HStack {
                            Label(app.name, systemImage: "macwindow").lineLimit(1)
                            Spacer()
                            Button("添加") {
                                model.routingOptions.applications.append(app)
                                showApplications = false
                            }
                        }.padding(8)
                    }
                }
            }.frame(maxHeight: 240)
            HStack { Spacer(); Button("关闭") { showApplications = false }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 480)
    }

    private var runtime: some View {
        card("系统代理与本机 PAC", icon: "switch.2") {
            HStack {
                Label(control.modeLabel, systemImage: control.needsRecovery ? "exclamationmark.triangle.fill" : control.localURL == nil ? "circle" : "circle.fill")
                    .foregroundStyle(control.needsRecovery ? Color.orange : Color.secondary)
                Spacer()
                if control.busy { ProgressView().controlSize(.small) }
            }
            if control.needsRecovery {
                Text(control.recoveryService.map { "「\($0.name)」的系统代理设置待恢复。先恢复原设置，再连接 macOS。" }
                    ?? "系统代理设置待恢复。先恢复原设置，再连接 macOS。")
                    .font(.callout).foregroundStyle(.orange)
                Button("恢复原网络代理设置") { control.restoreSystem() }.disabled(control.busy || model.busy)
            } else if let service = control.systemService {
                Text("已配置网络服务：\(service.name)。")
                    .font(.callout).foregroundStyle(.secondary)
                if !control.busy && !control.systemPACIsEffective {
                    Label("当前网络尚未使用这份 PAC。若刚切换网络，可以重新接入当前网络。", systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                    Button("接入当前网络") { model.reconnectPrimaryNetwork() }
                        .buttonStyle(ClayActionButtonStyle()).disabled(!model.running || model.busy)
                }
                HStack {
                    if control.followsRoutingMode {
                        Button("应用自定义 PAC") { model.publishPAC(to: .system(.customPolicy)) }
                            .disabled(!model.running || model.busy || control.busy)
                    } else {
                        Button("跟随流量模式") { model.publishPAC(to: .system(.followMode)) }
                            .disabled(!model.running || model.busy || control.busy)
                        Button("更新自定义 PAC") { model.publishPAC(to: .system(.customPolicy)) }
                            .disabled(!model.running || model.busy || control.busy || control.activePolicy == control.policy)
                    }
                    Button("恢复原网络代理设置") { control.restoreSystem() }.disabled(control.busy || model.busy)
                }
            } else {
                HStack {
                    Picker("网络服务", selection: $control.serviceID) {
                        Text(primaryServiceLabel).tag("")
                        ForEach(control.services, id: \.id) { Text($0.name + ($0.isPrimary ? "（主要）" : "")).tag($0.id) }
                    }.disabled(control.busy || model.busy)
                    Button { control.refreshServices() } label: { Image(systemName: "arrow.clockwise") }
                        .help("重新读取网络服务").accessibilityLabel("重新读取网络服务").disabled(control.busy || model.busy)
                    Button("连接 macOS") { model.connectSystem() }.disabled(!model.canConnectSystem)
                    Button("应用自定义 PAC") { model.connectSystem(using: .customPolicy) }.disabled(!model.canConnectSystem)
                }
                Text(selectedServiceDescription).font(.callout).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button(control.localURL == nil ? "启动本机 PAC" : "更新本机 PAC") { model.publishPAC(to: .local) }
                        .disabled(!model.running || model.busy || control.busy || control.activePolicy == control.policy)
                    if control.localURL != nil {
                        Button("停止本机 PAC") { control.stopLocal() }.disabled(control.busy || model.busy)
                    }
                }
            }
            if let url = control.localURL {
                HStack {
                    Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1)
                    Button("复制 PAC 地址") { model.copy(url.absoluteString) }
                }
            }
            if let active = control.activePolicy, active != control.policy {
                Label("规则已保存，当前 PAC 仍用上一版。点「更新」生效。", systemImage: "clock")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !control.message.isEmpty {
                Text(control.message).font(.callout).foregroundStyle(control.messageIsError ? Color.orange : Color.secondary)
            }
            Text("连接 macOS 后，非本地请求跟随流量模式。应用自定义 PAC 时，命中直连的请求可在到达内核之前直连。系统设置只影响使用 macOS 代理的应用。本机 PAC 地址可手动填入支持 PAC 的应用。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var primaryServiceLabel: String {
        control.services.first(where: \.isPrimary).map { "自动（\($0.name)）" } ?? "自动选择当前主要服务"
    }

    private var selectedServiceDescription: String {
        if let service = control.services.first(where: { $0.id == control.serviceID }) {
            return "连接时为「\(service.name)」启用系统 PAC。"
        }
        if control.services.contains(where: \.isPrimary) {
            return "连接时自动使用 macOS 当前的主要网络服务。"
        }
        return "未识别到主要网络服务。若自动连接失败，请刷新列表并选择正在使用的服务。"
    }

    private var policy: some View {
        card("局域网与默认策略", icon: "scope") {
            HStack {
                Picker("未命中规则", selection: $control.policy.defaultDecision) {
                    ForEach(PACDecision.allCases, id: \.self) { Text(label($0)).tag($0) }
                }.fixedSize()
                Spacer()
                Toggle("本地和私有地址直连", isOn: $control.policy.bypassLocal).toggleStyle(ClaySwitchStyle())
            }
            Text("同一目标命中多条时以第一条为准。回环地址始终直连；本地和私有地址的默认动作可以由显式规则覆盖。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("预览 PAC：输入域名、IP 或完整 URL", text: $preview).textFieldStyle(.roundedBorder)
            Text("此预览检查 PAC 域名和网段规则，不包含内核的应用或大陆规则。")
                .font(.caption).foregroundStyle(.secondary)
            if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { previewResult }
        }
    }

    @ViewBuilder private var previewResult: some View {
        switch Result(catching: { try control.policy.evaluate(preview) }) {
        case .success(let match):
            let note: String = {
                switch match.reason {
                case .loopback: return "回环保护"
                case .local: return "本地或私有地址"
                case .rule:
                    guard let index = match.ruleIndex, control.policy.rules.indices.contains(index) else { return "规则命中" }
                    return "第 \(index + 1) 条 · \(control.policy.rules[index].value)"
                case .fallback: return "默认策略"
                @unknown default: return "规则命中"
                }
            }()
            Label("\(label(match.decision)) · \(note)", systemImage: match.decision == .direct ? "arrow.right" : "arrow.triangle.branch")
                .font(.callout.weight(.semibold)).foregroundStyle(.tint)
        case .failure(let error):
            Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rules: some View {
        card("按顺序匹配", icon: "list.number") {
            HStack {
                Button("批量导入…") { showImport = true }
                Button("复制规则") { model.copy(control.policy.rules.map(\.exportLine).joined(separator: "\n")) }
                    .disabled(control.policy.rules.isEmpty)
                Spacer()
                Text("\(control.policy.rules.count) 条规则").font(.caption).foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 8) { ForEach(Array(control.policy.rules.enumerated()), id: \.element.id) { index, rule in
                HStack(spacing: 9) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.value).font(.callout.monospaced()).lineLimit(1)
                        Text(label(rule.kind)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(label(rule.decision)).font(.caption.weight(.medium)).foregroundStyle(rule.decision == .proxy ? Color.accentColor : Color.secondary)
                    Button { control.policy.rules.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0).help("向上移").accessibilityLabel("向上移")
                    Button { control.policy.rules.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index + 1 == control.policy.rules.count).help("向下移").accessibilityLabel("向下移")
                    Button("编辑") { kind = rule.kind; matchValue = rule.value; decision = rule.decision; editing = rule.id; formError = "" }
                    Button(role: .destructive) {
                        control.policy.rules.removeAll { $0.id == rule.id }
                        if editing == rule.id { resetForm() }
                    } label: { Image(systemName: "trash") }.help("删除规则").accessibilityLabel("删除规则")
                }.buttonStyle(.borderless).padding(9).background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            } }
            if control.policy.rules.isEmpty { Text("没有规则时，每个非本地目标走上面的默认策略。") .font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack(spacing: 8) {
                Picker("类型", selection: $kind) {
                    ForEach(PACRule.Kind.allCases, id: \.self) { Text(label($0)).tag($0) }
                }.labelsHidden().fixedSize()
                TextField(matchPlaceholder, text: $matchValue).textFieldStyle(.roundedBorder)
                Picker("动作", selection: $decision) {
                    ForEach(PACDecision.allCases, id: \.self) { Text(label($0)).tag($0) }
                }.labelsHidden().fixedSize()
                if editing != nil { Button("取消") { resetForm() } }
                Button(editing == nil ? "添加" : "保存") { saveRule() }
                    .disabled(matchValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !formError.isEmpty { Text(formError).font(.caption).foregroundStyle(.orange) }
            Text("IP 网段只匹配 URL 中明确写出的 IPv4 或 IPv6 地址，不额外查询 DNS。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批量导入 PAC 规则").font(.title2.bold())
            Text("每行一条，可用 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6，动作填 DIRECT 或 PROXY。导入后追加到列表末尾。")
                .foregroundStyle(.secondary)
            Text("DOMAIN-SUFFIX,example.com,PROXY").font(.caption.monospaced()).foregroundStyle(.secondary)
            TextEditor(text: $importText).font(.body.monospaced()).frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)))
                .accessibilityLabel("PAC 规则文本")
            if !importError.isEmpty { Text(importError).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消") { showImport = false }.keyboardShortcut(.cancelAction)
                Button("追加规则") {
                    do {
                        let imported = try PACPolicy.importRules(importText)
                        control.policy.rules.append(contentsOf: imported)
                        showImport = false
                    } catch { importError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(23).frame(width: 550)
    }

    private func saveRule() {
        do {
            let updated = try PACRule(kind: kind, value: matchValue, decision: decision)
            if let editing, let index = control.policy.rules.firstIndex(where: { $0.id == editing }) {
                control.policy.rules[index] = updated
            } else { control.policy.rules.append(updated) }
            resetForm()
        } catch { formError = error.localizedDescription }
    }

    private func resetForm() { editing = nil; matchValue = ""; formError = "" }

    private var matchPlaceholder: String {
        switch kind {
        case .ipCIDR: return "例如 10.0.0.0/8"
        case .ipCIDR6: return "例如 2001:db8::/32"
        default: return "例如 example.com"
        }
    }

    private func label(_ decision: PACDecision) -> String { decision == .direct ? "直连" : "走代理" }
    private func label(_ kind: PACRule.Kind) -> String {
        switch kind {
        case .domain: return "完整域名 / IP"
        case .domainSuffix: return "域名后缀"
        case .domainKeyword: return "域名关键词"
        case .ipCIDR: return "IPv4 网段"
        case .ipCIDR6: return "IPv6 网段"
        @unknown default: return kind.rawValue
        }
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }.clayCard()
    }
}
