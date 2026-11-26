import CLAYCore
import Combine
import Foundation
import NetworkExtension

@MainActor final class LabConnection: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case rule, global
        var id: Self { self }
        var engineValue: Int32 { self == .rule ? 0 : 1 }
    }

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var busy = false
    @Published private(set) var failure = false
    private var manager: NETunnelProviderManager?

    var active: Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting: return true
        default: return false
        }
    }

    func readStatus() {
        status = manager?.connection.status ?? .invalid
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            manager = try await ownConfiguration()
            readStatus()
        } catch {
            failure = true
        }
    }

    func start(node: NodeProfile, mode: Mode) async {
        guard !busy, !active else { return }
        busy = true
        failure = false
        defer { busy = false }
        do {
            let route = try PACRule(kind: .ipCIDR, value: LabContract.destination + "/32", decision: .proxy)
            let policy = PACPolicy(rules: [route], defaultDecision: .direct, bypassLocal: false)
            let profile = try CoreConfig.makePacketProfile(nodes: [node], policy: policy)
            guard (1...LabContract.maximumProfile).contains(profile.count) else {
                throw LabContract.Failure.invalidRequest
            }
            let manager = try await ownConfiguration() ?? NETunnelProviderManager()
            self.manager = manager
            readStatus()
            guard !active else { return }
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = try Self.providerID()
            configuration.serverAddress = LabContract.remoteAddress
            // Preferences contain only the provider identity and lab route label.
            // Node credentials are sent as per-start options, without on-demand.
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "CLAY Tunnel Lab"
            manager.isEnabled = true
            manager.isOnDemandEnabled = false
            manager.onDemandRules = nil
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            guard let session = manager.connection as? NETunnelProviderSession else {
                throw LabContract.Failure.setup
            }
            try session.startTunnel(options: [LabContract.profileKey: profile as NSData,
                                              LabContract.modeKey: NSNumber(value: mode.engineValue)])
            readStatus()
        } catch {
            failure = true
            readStatus()
        }
    }

    func stop() {
        failure = false
        manager?.connection.stopVPNTunnel()
        readStatus()
    }

    private static func providerID() throws -> String {
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else { throw LabContract.Failure.setup }
        return id + ".provider"
    }

    private func ownConfiguration() async throws -> NETunnelProviderManager? {
        let id = try Self.providerID()
        let own = try await NETunnelProviderManager.loadAllFromPreferences().filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == id
        }
        guard own.count <= 1 else { throw LabContract.Failure.setup }
        return own.first
    }
}
