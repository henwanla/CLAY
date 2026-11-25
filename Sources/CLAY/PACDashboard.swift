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

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            runtime
            policy
            rules
        }
        .onAppear { control.refreshServices() }
        .sheet(isPresented: $showImport, onDismiss: { importText = ""; importError = "" }) { importSheet }
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
                Text("已配置网络服务：\(service.name)。切换到其他网络服务时，先恢复原设置，再连接到新服务。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("更新系统 PAC") { model.publishPAC(toSystem: true) }
                        .disabled(!model.running || model.busy || control.busy || control.activePolicy == control.policy)
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
                }
                Text(selectedServiceDescription).font(.callout).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button(control.localURL == nil ? "启动本机 PAC" : "更新本机 PAC") { model.publishPAC(toSystem: false) }
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
            Text("系统 PAC 只影响遵循 macOS 代理设置的应用，应用设置时系统可能请求授权。本机 PAC 地址可手动填入支持 PAC 的应用。")
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
        card("默认策略与测试", icon: "scope") {
            HStack {
                Picker("未命中规则", selection: $control.policy.defaultDecision) {
                    ForEach(PACDecision.allCases, id: \.self) { Text(label($0)).tag($0) }
                }.fixedSize()
                Spacer()
                Toggle("本地和私有地址直连", isOn: $control.policy.bypassLocal)
            }
            Text("同一目标命中多条时以第一条为准。回环地址始终直连；本地和私有地址的默认动作可以由显式规则覆盖。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("输入域名、IP 或完整 URL，测试会走哪条规则", text: $preview).textFieldStyle(.roundedBorder)
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
                TextField(kind == .ipCIDR ? "例如 10.0.0.0/8" : "例如 example.com", text: $matchValue).textFieldStyle(.roundedBorder)
                Picker("动作", selection: $decision) {
                    ForEach(PACDecision.allCases, id: \.self) { Text(label($0)).tag($0) }
                }.labelsHidden().fixedSize()
                if editing != nil { Button("取消") { resetForm() } }
                Button(editing == nil ? "添加" : "保存") { saveRule() }
                    .disabled(matchValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !formError.isEmpty { Text(formError).font(.caption).foregroundStyle(.orange) }
            Text("IP 网段只匹配 URL 中明确写出的 IPv4 地址，不额外查询 DNS。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批量导入 PAC 规则").font(.title2.bold())
            Text("每行一条，可用 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR，动作填 DIRECT 或 PROXY。导入后追加到列表末尾。")
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

    private func label(_ decision: PACDecision) -> String { decision == .direct ? "直连" : "走代理" }
    private func label(_ kind: PACRule.Kind) -> String {
        switch kind {
        case .domain: return "完整域名 / IP"
        case .domainSuffix: return "域名后缀"
        case .domainKeyword: return "域名关键词"
        case .ipCIDR: return "IPv4 网段"
        @unknown default: return kind.rawValue
        }
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
    }
}
