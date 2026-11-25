import CLAYCore
import Foundation
import SwiftUI

@MainActor final class PACControl: ObservableObject {
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
    @Published private(set) var recoveryService: SystemPACService?
    @Published private(set) var activePolicy: PACPolicy?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var messageIsError = false

    private static let preferenceKey = "clay.pac-policy.v1"
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
    var modeLabel: String {
        if needsRecovery { return "PAC 待恢复" }
        if let systemService { return "系统 PAC · \(systemService.name)" }
        return localURL == nil ? "手动接入" : "本机 PAC"
    }

    func refreshServices() {
        services = SystemPACManager.services()
        if !serviceID.isEmpty, !services.contains(where: { $0.id == serviceID }) { serviceID = "" }
        refreshRecovery()
    }

    private func refreshRecovery() {
        guard systemService == nil else { return }
        do { recoveryService = try manager.pendingRecovery() }
        catch { display(error.localizedDescription, error: true) }
    }

    /// Starting a local PAC endpoint never changes macOS settings. Applying to macOS
    /// creates the new endpoint first, so the live system setting never points at an
    /// unstarted server. Explicitly updating uses a new URL to invalidate client caches.
    func publish(port: Int, toSystem: Bool) {
        guard !busy, !needsRecovery, toSystem || systemService == nil else { return }
        let draft = policy
        let script: String
        do { script = try draft.makeScript(proxyPort: port) }
        catch { display(error.localizedDescription, error: true); return }
        let id = UUID()
        generation = id; busy = true
        display(toSystem ? "正在准备系统 PAC…" : "正在准备本机 PAC…")
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if generation == id { generation = nil; busy = false; operation = nil } }
            var candidate: PACServer?
            defer { candidate?.stop() }
            do {
                let next: PACServer
                if let server, activePolicy == draft { next = server }
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
                        if let pending = try? manager.pendingRecovery() { recoveryService = pending }
                        throw error
                    }
                    recoveryService = nil
                }

                if next !== server {
                    let previous = server
                    server = next; candidate = nil
                    localURL = next.url; activePolicy = draft
                    previous?.stop()
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
            alternateServers.forEach { $0.stop() }; alternateServers.removeAll()
            switch result {
            case .restored: display("已恢复原网络代理设置。")
            case .externallyChanged: display("设置已由其他工具接管，已保留它的设置。")
            case .noBackup: display("没有需要恢复的系统 PAC 设置。")
            }
            return true
        } catch {
            refreshRecovery()
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
        localURL = nil; activePolicy = nil
    }

    private func display(_ value: String, error: Bool = false) {
        message = value; messageIsError = error
    }
}
