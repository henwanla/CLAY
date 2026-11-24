import AppKit
import CLAYCore
import SwiftUI
import UniformTypeIdentifiers

struct TrafficPoint: Identifiable {
    let id = UUID()
    let time: Date
    let upload: Int64
    let download: Int64
    let segment: Int
}

enum Probe {
    case ok(Int), failed
    var text: String { switch self { case .ok(let n): return "\(n) ms"; case .failed: return "探测失败" } }
    func change(from earlier: Probe) -> String {
        switch (earlier, self) {
        case (.failed, .ok): return "恢复连通"
        case (.ok, .failed): return "变为不可用"
        case (.failed, .failed): return "仍不可用"
        case (.ok(let old), .ok(let new)):
            let difference = new - old
            return difference == 0 ? "延迟不变" : "延迟 \(difference > 0 ? "+" : "")\(difference) ms"
        }
    }
    var report: String { switch self { case .ok(let n): return "reachable (\(n) ms)"; case .failed: return "no response" } }
}

@MainActor final class Workspace: ObservableObject {
    @Published var nodes: [NodeProfile] = []
    @Published var active: UUID?
    @Published var engine: URL?
    @Published var issues: [ImportError: Int] = [:]
    @Published var hasImported = false
    @Published var proxyAddress: String?
    @Published var status = "等待配置"
    @Published var busy = false
    @Published private(set) var probes: [UUID: Probe] = [:]
    @Published var lastProbe: Date?
    @Published private(set) var latestBatch: [UUID: Probe] = [:]
    @Published private(set) var previousBatch: [UUID: Probe] = [:]
    @Published var presentImport = false
    @Published var presentSubscription = false
    @Published private(set) var subscriptions: [SubscriptionSummary] = []
    @Published private(set) var selectedSubscription: UUID?
    @Published private(set) var fetchingSubscription = false
    @Published private(set) var subscriptionMessage = ""
    @Published private(set) var sourceChangePending = false
    @Published private(set) var telemetry: ProxyTelemetry?
    @Published private(set) var trafficHistory: [TrafficPoint] = []
    @Published private(set) var telemetryStale = false
    @Published private(set) var connectionActionBusy = false
    @Published private(set) var connectionMessage = ""
    let pac: PACControl
    static let probeTarget = URL(string: "https://www.gstatic.com/generate_204")!
    private var core: CoreSession?
    private var pendingStart: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var subscriptionTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var trafficSegment = 0
    private let store: SubscriptionStore
    private var catalog = SubscriptionCatalog()
    private var subscriptionResults: [UUID: ImportResult] = [:]
    private var manualResults: ImportResult?
    private var liveSource: UUID?
    private var shuttingDown = false
    private static let enginePreference = "mihomoExecutablePath"

    init(store: SubscriptionStore = SubscriptionStore(), pac: PACControl? = nil) {
        self.store = store
        self.pac = pac ?? PACControl()
        let nearby = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Dependencies/mihomo")
        if let path = UserDefaults.standard.string(forKey: Self.enginePreference),
           FileManager.default.isExecutableFile(atPath: path) {
            engine = URL(fileURLWithPath: path)
        } else if Bundle.main.object(forInfoDictionaryKey: "CLAYUseAdjacentMihomo") as? Bool == true,
                  FileManager.default.isExecutableFile(atPath: nearby.path) {
            engine = nearby
        }
        do {
            catalog = try store.load()
            for entry in catalog.entries { subscriptionResults[entry.id] = SubscriptionImporter.parse(entry.content) }
            publishCatalog()
            if selectedSubscription != nil { applySelectedSource() }
        } catch { subscriptionMessage = "无法读取本地订阅记录。" }
    }
    var chosen: NodeProfile? { nodes.first { $0.id == active } }
    var running: Bool { proxyAddress != nil }
    var canToggleProxy: Bool { !shuttingDown && (running || (!busy && !pac.hasLiveOwnership && engine != nil && chosen != nil)) }
    var menuStatus: String {
        if running { return "代理运行中" }
        if pendingStart != nil { return "代理启动中" }
        return "代理已停止"
    }
    var canUseManual: Bool { manualResults != nil && selectedSubscription != nil }

    func monitorHealth() {
        guard healthTask == nil else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1.5)) } catch { break }
                self?.checkHealth()
            }
        }
    }

    private func monitorTraffic(_ session: CoreSession) {
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self, weak session] in
            while !Task.isCancelled {
                guard let session, session.isRunning else { return }
                do {
                    let sample = try await session.telemetry()
                    guard !Task.isCancelled, let self, core === session else { return }
                    telemetry = sample; telemetryStale = false
                    if let upload = sample.uploadRate, let download = sample.downloadRate {
                        trafficHistory.append(TrafficPoint(time: sample.sampledAt, upload: upload, download: download, segment: trafficSegment))
                        if trafficHistory.count > 60 { trafficHistory.removeFirst(trafficHistory.count - 60) }
                    }
                } catch {
                    guard !Task.isCancelled, let self, core === session else { return }
                    if !telemetryStale { telemetryStale = true; trafficSegment += 1 }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func routeLabel(_ name: String) -> String {
        nodes.first(where: { $0.localName == name })?.name ?? name
    }

    func closeConnection(_ id: UUID? = nil) {
        guard let core, running, !connectionActionBusy else { return }
        connectionActionBusy = true; connectionMessage = ""
        connectionTask = Task { [weak self] in
            defer { if let self, self.core === core { self.connectionActionBusy = false; self.connectionTask = nil } }
            do {
                if let id { try await core.closeConnection(id) }
                else { try await core.closeAllConnections() }
                guard !Task.isCancelled, let self, self.core === core else { return }
                connectionMessage = id == nil ? "已请求关闭全部连接。" : "已请求关闭这条连接。"
            } catch {
                guard !Task.isCancelled, let self, self.core === core else { return }
                connectionMessage = "未能关闭连接；它可能已自行结束，请查看下一次刷新。"
            }
        }
    }

    func chooseEngine() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.message = "选择你信任的 Mihomo 可执行文件"
        guard picker.runModal() == .OK, let file = picker.url else { return }
        guard FileManager.default.isExecutableFile(atPath: file.path) else { status = "所选文件不可执行"; return }
        UserDefaults.standard.set(file.path, forKey: Self.enginePreference)
        engine = file; status = nodes.isEmpty ? "等待导入节点" : "可启动"
    }
    func importFile() -> Bool {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false
        picker.allowedContentTypes = [.json, .plainText] + ["yaml", "yml"].compactMap { UTType(filenameExtension: $0) }
        guard picker.runModal() == .OK, let file = picker.url else { return false }
        do {
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= ProfileImporter.maxBytes else { throw ImportError.malformed }
            return applyImport(try String(contentsOf: file, encoding: .utf8))
        } catch { issues = [.malformed: 1]; hasImported = true; status = "读取失败：需要不超过 2 MiB 的 UTF-8 文件"; return false }
    }
    @discardableResult func applyImport(_ input: String) -> Bool {
        guard !running, !busy else { return false }
        let imported = SubscriptionImporter.parse(input); issues = imported.issues; hasImported = true
        guard !imported.profiles.isEmpty else { status = "未导入节点，原列表保留"; return false }
        manualResults = imported
        if selectedSubscription != nil {
            chooseSource(nil)
            if selectedSubscription != nil { status = "手动列表已导入，但无法保存列表切换"; return false }
        } else { applySelectedSource() }
        return true
    }

    func addSubscription(name: String, input: String) {
        guard !fetchingSubscription, !shuttingDown else { return }
        do {
            let url = try SubscriptionImporter.validatedURL(input.trimmingCharacters(in: .whitespacesAndNewlines))
            if let existing = catalog.entries.first(where: { $0.url == url }) {
                download(existing, select: true)
            } else {
                let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let entry = SubscriptionCatalog.Entry(id: UUID(), name: label.isEmpty ? "订阅 \(catalog.entries.count + 1)" : String(label.prefix(80)), url: url, content: "", updated: .now)
                download(entry, select: true)
            }
        } catch { subscriptionMessage = error.localizedDescription }
    }

    func refreshSubscription(_ id: UUID) {
        guard !fetchingSubscription, !shuttingDown, let entry = catalog.entries.first(where: { $0.id == id }) else { return }
        download(entry, select: false)
    }

    private func download(_ entry: SubscriptionCatalog.Entry, select: Bool) {
        fetchingSubscription = true; subscriptionMessage = "正在下载订阅…"
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { fetchingSubscription = false; subscriptionTask = nil }
            do {
                let (content, imported) = try await SubscriptionImporter.fetch(entry.url)
                try Task.checkCancellation()
                var next = catalog
                var updated = entry; updated.content = content; updated.updated = .now
                if let index = next.entries.firstIndex(where: { $0.id == entry.id }) { next.entries[index] = updated }
                else { next.entries.append(updated) }
                if select { next.selected = entry.id }
                guard saveCatalog(next) else { return }
                subscriptionResults[entry.id] = imported
                publishCatalog()
                if select || selectedSubscription == entry.id { installSelectedSource() }
                let skipped = imported.issues.values.reduce(0, +)
                let detail = skipped == 0 ? "" : "，跳过 \(skipped) 项"
                subscriptionMessage = "已更新 \(imported.profiles.count) 个节点\(detail)。"
                if select { presentSubscription = false }
            } catch is CancellationError {
                return
            } catch {
                subscriptionMessage = "\(error.localizedDescription) 上次可用的节点列表保持不变。"
            }
        }
    }

    func chooseSource(_ id: UUID?) {
        guard id != selectedSubscription else { return }
        if let id, subscriptionResults[id]?.profiles.isEmpty != false { return }
        var next = catalog; next.selected = id
        guard saveCatalog(next) else { return }
        publishCatalog(); installSelectedSource()
    }

    func removeSubscription(_ id: UUID) {
        guard !fetchingSubscription else { return }
        let wasSelected = selectedSubscription == id
        var next = catalog; next.entries.removeAll { $0.id == id }
        if wasSelected { next.selected = next.entries.first { subscriptionResults[$0.id]?.profiles.isEmpty == false }?.id }
        guard saveCatalog(next) else { return }
        subscriptionResults.removeValue(forKey: id); publishCatalog()
        if wasSelected { installSelectedSource() }
        subscriptionMessage = "订阅已移除。"
    }

    private func saveCatalog(_ next: SubscriptionCatalog) -> Bool {
        do { try store.save(next); catalog = next; return true }
        catch { subscriptionMessage = "无法保存本地订阅记录。原列表保持不变。"; return false }
    }

    private func publishCatalog() {
        selectedSubscription = catalog.selected
        subscriptions = catalog.entries.map { entry in
            SubscriptionSummary(id: entry.id, name: entry.name, count: subscriptionResults[entry.id]?.profiles.count ?? 0, updated: entry.updated)
        }
    }

    private func installSelectedSource() {
        if running || pendingStart != nil { sourceChangePending = true }
        else { applySelectedSource() }
    }

    private func applySelectedSource() {
        let previous = liveSource == selectedSubscription ? chosen : nil
        let imported = selectedSubscription.flatMap { subscriptionResults[$0] } ?? manualResults
        nodes = imported?.profiles ?? []; issues = imported?.issues ?? [:]; hasImported = imported != nil
        active = previous.flatMap { old in nodes.first { $0.id == old.id || $0.hasSameConnection(as: old) } }?.id ?? nodes.first?.id
        liveSource = selectedSubscription; sourceChangePending = false
        probes = [:]; lastProbe = nil; latestBatch = [:]; previousBatch = [:]
        status = engine == nil ? "等待选择 Mihomo" : nodes.isEmpty ? "等待导入节点" : "可启动"
    }

    func toggleProxy() { if running { stop() } else { start() } }

    func publishPAC(toSystem: Bool) {
        guard !shuttingDown, let core, core.isRunning else { return }
        pac.publish(port: core.proxyPort, toSystem: toSystem)
    }

    func start() {
        guard !shuttingDown, !busy, !running, !pac.hasLiveOwnership, let engine, let selected = chosen else { return }
        busy = true; status = "正在启动 Mihomo…"
        pendingStart = Task { [weak self] in
            guard let self else { return }
            defer {
                busy = false; pendingStart = nil
                if !running, sourceChangePending, !shuttingDown {
                    let startStatus = status
                    applySelectedSource()
                    status = startStatus
                }
            }
            do {
                let session = try await CoreSession.start(engine: engine, nodes: nodes, active: selected)
                if Task.isCancelled { session.stopAndWait(); return }
                core = session; proxyAddress = session.proxyAddress; status = "本机代理运行中"
                monitorTraffic(session)
            } catch let error as SessionError { status = Self.sessionMessage(error) }
            catch { status = "启动已取消或失败" }
        }
    }
    @discardableResult func stop() -> Bool {
        guard pac.releaseForStop(interactive: true) else {
            status = "未能恢复系统 PAC · 代理仍在运行。请在 PAC 页面重试。"
            return false
        }
        clearSession()
        status = "已停止"
        return true
    }

    private func clearSession() {
        sessionTask?.cancel()
        telemetryTask?.cancel(); telemetryTask = nil
        connectionTask?.cancel(); connectionTask = nil; connectionActionBusy = false; connectionMessage = ""
        telemetry = nil; trafficHistory = []; telemetryStale = false; trafficSegment = 0
        core?.stopAndWait(); core = nil; proxyAddress = nil
        if sourceChangePending { applySelectedSource() }
    }
    @discardableResult func shutdown() async -> Bool {
        shuttingDown = true
        let start = pendingStart
        start?.cancel(); await start?.value
        guard stop() else { shuttingDown = false; return false }
        healthTask?.cancel(); healthTask = nil
        subscriptionTask?.cancel()
        return true
    }
    func checkHealth() {
        guard let core, !core.isRunning else { return }
        let restored = pac.releaseForStop(interactive: false)
        clearSession()
        status = restored ? "Mihomo 已退出，可以重试启动" : "Mihomo 已退出 · 请在 PAC 页面恢复系统设置。"
    }
    func select(_ node: NodeProfile) {
        guard !busy else { return }
        guard let core else { active = node.id; return }
        busy = true
        sessionTask = Task {
            defer { busy = false; sessionTask = nil }
            do {
                try await core.switchTo(node)
                guard self.core === core, !Task.isCancelled else { return }
                active = node.id; status = "节点已切换"
            } catch {
                guard self.core === core, !Task.isCancelled else { return }
                status = "切换失败，保留上一个节点"; checkHealth()
            }
        }
    }
    func measure(_ selection: [NodeProfile], compare: Bool = false) {
        guard let core, !busy else { return }
        busy = true; status = "正在通过节点探测…"
        sessionTask = Task {
            defer { busy = false; sessionTask = nil }
            let target = Self.probeTarget
            var results: [UUID: Probe] = [:]
            // Small batches prevent a large import from creating a burst of outbound requests.
            for offset in stride(from: 0, to: selection.count, by: 4) {
                guard core.isRunning, !Task.isCancelled else { break }
                let chunk = Array(selection.dropFirst(offset).prefix(4))
                await withTaskGroup(of: (UUID, Probe).self) { group in
                    for node in chunk { group.addTask { @MainActor in
                        do { return (node.id, .ok(try await core.delay(node, target: target))) }
                        catch { return (node.id, .failed) }
                    } }
                    for await (id, result) in group where self.core === core && !Task.isCancelled {
                        probes[id] = result; results[id] = result
                    }
                }
                guard self.core === core, !Task.isCancelled else { return }
                lastProbe = .now
            }
            guard self.core === core, !Task.isCancelled else { return }
            if compare && results.count == selection.count {
                previousBatch = latestBatch; latestBatch = results
            }
            status = "探测结束"; checkHealth()
        }
    }
    func copy(_ content: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(content, forType: .string) }
    func copySummary() {
        let results = nodes.enumerated().map { i, node in
            let comparison: String
            if let before = previousBatch[node.id], let after = latestBatch[node.id] {
                comparison = " · last two batches: \(before.report) → \(after.report)"
            } else { comparison = "" }
            return "Node \(i + 1): \(node.protocolName.uppercased()) · \(node.transport) · \(node.security) · \(probes[node.id]?.report ?? "not tested")\(comparison)"
        }
        let warnings = issues.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue): \($0.value)" }
        let summary = ["CLAY connection report", "Engine session: \(running ? "ready" : "stopped")", "Imported: \(nodes.count)", "Target: \(Self.probeTarget.host ?? "—")"]
        copy((summary + warnings + results).joined(separator: "\n")); status = "已复制脱敏报告"
    }
    static func issue(_ e: ImportError) -> String {
        switch e { case .malformed: return "文件或分享链接格式不正确"
        case .unsupportedProtocol: return "节点协议不支持（目前支持 VMess / VLESS）"
        case .unsupportedTransport: return "传输方式不支持"
        case .unsupportedOption: return "有无法迁移的选项，或超过节点上限"
        case .invalidAccount: return "地址、端口、UUID 或 REALITY 参数无效"
        case .notProxyOutbound: return "已略过直连、拒绝或 DNS 出站" }
    }
    private static func sessionMessage(_ e: SessionError) -> String {
        switch e { case .engineMissing: return "未找到可执行的 Mihomo"
        case .exitedDuringStart: return "Mihomo 启动后立即退出，请检查内核版本和节点格式"
        case .controlUnavailable: return "未能确认 Mihomo 控制接口或代理端口已就绪"
        case .portsUnavailable: return "无法为本机代理分配独立端口"
        case .setupFailed: return "无法创建本次运行配置"
        default: return "Mihomo 会话启动失败" }
    }
}
