import CLAYCore
import Foundation
import SwiftUI

@MainActor final class PACControl: ObservableObject {
    enum SystemRouting { case followMode, customPolicy }
    enum Endpoint {
        case local, system(SystemRouting)

        var systemRouting: SystemRouting? {
            if case .system(let routing) = self { return routing }
            return nil
        }
    }

    @Published var policy: PACPolicy {
        didSet {
            guard let data = try? JSONEncoder().encode(policy) else { return }
            preferences.set(data, forKey: Self.preferenceKey)
        }
    }
    @Published var serviceID = ""
    @Published private(set) var services: [SystemPACService] = []
    @Published private(set) var localURL: URL?
    @Published private(set) var systemService: SystemPACService?
    @Published private(set) var systemPACIsEffective = false
    @Published private(set) var recoveryService: SystemPACService?
    @Published private(set) var activePolicy: PACPolicy?
    @Published private(set) var followsRoutingMode = false
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var messageIsError = false

    private static let preferenceKey = "clay.pac-policy.v1"
    static let followPolicy = PACPolicy(rules: [], defaultDecision: .proxy, bypassLocal: false)
    private let preferences: UserDefaults
    private let manager: SystemPACManager
    private var server: PACServer?
    private var alternateServers: [PACServer] = []
    private var uncertainOwnership = false
    private var operation: Task<Void, Never>?
    private var generation: UUID?

    init(manager: SystemPACManager? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.manager = manager ?? SystemPACManager()
        if let data = preferences.data(forKey: Self.preferenceKey), let saved = try? JSONDecoder().decode(PACPolicy.self, from: data) {
            policy = saved
        } else { policy = .standard }
        refreshRecovery()
    }

    var hasLiveOwnership: Bool { systemService != nil || uncertainOwnership }
    var needsRecovery: Bool { recoveryService != nil || uncertainOwnership }

    #if CLAY_DOCUMENTATION
    func showDocumentationSystemProxy() {
        systemService = SystemPACService(id: "sample", name: "示例网络", isPrimary: true)
        systemPACIsEffective = true
        followsRoutingMode = true
    }
    #endif

    var modeLabel: String {
        if needsRecovery { return "PAC 待恢复" }
        if let systemService {
            let kind = followsRoutingMode ? "系统代理" : "自定义 PAC"
            return systemPACIsEffective ? "\(kind)已启用 · \(systemService.name)" : "\(kind)已配置，未成为系统默认 · \(systemService.name)"
        }
        if localURL == nil { return "手动接入" }
        return followsRoutingMode ? "本机 PAC · 跟随流量模式" : "本机 PAC"
    }

    func refreshServices() {
        services = SystemPACManager.services()
        if !serviceID.isEmpty, !services.contains(where: { $0.id == serviceID }) { serviceID = "" }
        refreshRecovery()
        refreshEffectiveState()
    }

    /// Keep the status bar current without writing any settings or showing a prompt.
    func refreshEffectiveState() {
        let effective = !needsRecovery && systemService != nil && (localURL.map(manager.isEffective) ?? false)
        if effective != systemPACIsEffective { systemPACIsEffective = effective }
    }

    private func refreshRecovery() {
        guard systemService == nil else { return }
        do { recoveryService = try manager.pendingRecovery() }
        catch { display(error.localizedDescription, error: true) }
    }

    /// Starting a local PAC endpoint never changes macOS settings. Applying to macOS
    /// creates the new endpoint first, so the live system setting never points at an
    /// unstarted server. Explicitly updating uses a new URL to invalidate client caches.
    func publish(port: Int, to endpoint: Endpoint) {
        let toSystem = endpoint.systemRouting != nil
        let followsMode = endpoint.systemRouting == .followMode
        guard !busy, !needsRecovery, toSystem || systemService == nil else { return }
        // For the default system connection, leave non-local routing to Mihomo.
        // Custom PAC can still decide on a route before the request reaches it.
        let draft: PACPolicy? = followsMode ? nil : policy
        let script: String
        do { script = try (draft ?? Self.followPolicy).makeScript(proxyPort: port) }
        catch { display(error.localizedDescription, error: true); return }
        let id = UUID()
        generation = id; busy = true
        display(toSystem ? "正在准备系统 PAC…" : "正在准备本机 PAC…")
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == id {
                    generation = nil; busy = false; operation = nil
                    refreshEffectiveState()
                }
            }
            var candidate: PACServer?
            defer { candidate?.stop() }
            do {
                let next: PACServer
                if let server, activePolicy == draft, followsRoutingMode == followsMode { next = server }
                else { next = try await PACServer.start(script: script); candidate = next }
                try Task.checkCancellation()
                guard generation == id else { return }

                if toSystem {
                    do {
                        if systemService != nil {
                            if next !== server { systemService = try manager.update(url: next.url) }
                        } else {
                            systemService = try manager.enable(url: next.url, serviceID: serviceID.isEmpty ? nil : serviceID)
                        }
                    } catch {
                        // A commit that could not be verified may have installed either URL.
                        // Keep any candidate listener until an explicit recovery settles ownership.
                        if let failure = error as? SystemPACError, case .recoveryRequired = failure { uncertainOwnership = true }
                        if let new = candidate, uncertainOwnership || manager.needsListener(at: new.url) {
                            uncertainOwnership = true
                            alternateServers.append(new); candidate = nil
                        }
                        systemService = manager.managedService
                        if uncertainOwnership || systemService == nil { recoveryService = try? manager.pendingRecovery() }
                        throw error
                    }
                    recoveryService = nil
                }

                if next !== server {
                    let previous = server
                    server = next; candidate = nil
                    localURL = next.url; activePolicy = draft; followsRoutingMode = followsMode
                    // configd can still refer to the previous endpoint after Apply.
                    if toSystem {
                        alternateServers.removeAll { old in
                            guard !self.manager.needsListener(at: old.url) else { return false }
                            old.stop(); return true
                        }
                    }
                    if let previous {
                        if toSystem && manager.needsListener(at: previous.url) { alternateServers.append(previous) }
                        else { previous.stop() }
                    }
                }
                display(toSystem ? "PAC 已应用到 \(systemService?.name ?? "所选网络服务")。" : "本机 PAC 地址已就绪。")
            } catch is CancellationError {
                return
            } catch {
                if generation == id { display(error.localizedDescription, error: true) }
            }
        }
    }

    @discardableResult func restoreSystem(interactive: Bool = true) -> Bool {
        guard !busy else { return false }
        do {
            let result = try manager.restore(interactive: interactive)
            systemService = nil; recoveryService = nil; uncertainOwnership = false
            refreshEffectiveState()
            alternateServers.forEach { $0.stop() }; alternateServers.removeAll()
            switch result {
            case .restored: display("已恢复原网络代理设置。")
            case .externallyChanged: display("设置已由其他工具接管，已保留它的设置。")
            case .noBackup: display("没有需要恢复的系统 PAC 设置。")
            }
            return true
        } catch {
            if let systemService { recoveryService = systemService }
            else { refreshRecovery() }
            refreshEffectiveState()
            display(error.localizedDescription, error: true)
            return false
        }
    }

    func stopLocal() {
        guard !busy, !hasLiveOwnership else { return }
        closeServers()
        display("本机 PAC 已停止。")
    }

    /// Called before stopping the proxy or quitting. Do not close the local
    /// listeners if an owned system setting could still require them.
    @discardableResult func releaseForStop(interactive: Bool) -> Bool {
        operation?.cancel(); operation = nil; generation = nil; busy = false
        if hasLiveOwnership, !restoreSystem(interactive: interactive) { return false }
        closeServers()
        return true
    }

    private func closeServers() {
        server?.stop(); server = nil
        alternateServers.forEach { $0.stop() }; alternateServers.removeAll()
        localURL = nil; activePolicy = nil; followsRoutingMode = false
        refreshEffectiveState()
    }

    private func display(_ value: String, error: Bool = false) {
        message = value; messageIsError = error
    }
}
