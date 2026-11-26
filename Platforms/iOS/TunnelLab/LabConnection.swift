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

    enum UpdateOutcome: String {
        case applied, rejected, unavailable, unknown
    }

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var busy = false
    @Published private(set) var failure = false
    @Published private(set) var updating = false
    @Published private(set) var updateOutcome: UpdateOutcome?
    @Published private(set) var liveTarget: LabContract.Target?
    @Published private(set) var readingTarget = false
    private var manager: NETunnelProviderManager?
    private var updateID: UUID?
    private var pendingReply: Reply?
    private var targetReadID: UUID?
    private var targetReply: Reply?

    var active: Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting: return true
        default: return false
        }
    }

    func readStatus() {
        status = manager?.connection.status ?? .invalid
        if status != .connected {
            invalidateUpdate()
            invalidateTarget()
        }
    }

    func refresh() async {
        guard !busy, !updating else { return }
        // Reuse the connection object while it represents an active session.
        // Loading another manager must not leave callbacks from the old one valid.
        readStatus()
        if !active {
            busy = true
            do {
                let loaded = try await ownConfiguration()
                invalidateTarget()
                manager = loaded
                readStatus()
            } catch {
                failure = true
            }
            busy = false
        }
        await readLiveTarget()
    }

    func start(node: NodeProfile, mode: Mode, target: LabContract.Target) async {
        guard !busy, !active else { return }
        busy = true
        failure = false
        defer { busy = false }
        do {
            let profile = try Self.profile(for: node)
            let manager = try await ownConfiguration() ?? NETunnelProviderManager()
            invalidateTarget()
            self.manager = manager
            readStatus()
            guard !active else { return }
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = try Self.providerID()
            configuration.serverAddress = LabContract.remoteAddress
            // The target and node credentials travel only in the per-start options.
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
                                              LabContract.modeKey: NSNumber(value: mode.engineValue),
                                              LabContract.addressKey: target.address as NSString,
                                              LabContract.portKey: String(target.port) as NSString])
            readStatus()
        } catch {
            failure = true
            readStatus()
        }
    }

    func stop() {
        failure = false
        invalidateUpdate()
        invalidateTarget()
        manager?.connection.stopVPNTunnel()
        readStatus()
    }

    func readLiveTarget() async {
        readStatus()
        guard status == .connected, !busy, liveTarget == nil, !readingTarget,
              let manager, let session = manager.connection as? NETunnelProviderSession else { return }
        let id = UUID()
        targetReadID = id
        readingTarget = true
        let reply = await send(LabContract.targetRequest, to: session, forTarget: true)
        guard targetReadID == id else { return }
        targetReadID = nil
        targetReply = nil
        readingTarget = false
        guard self.manager === manager, session.status == .connected else { return }
        liveTarget = LabContract.readTarget(reply)
    }

    func apply(node: NodeProfile, mode: Mode) async {
        readStatus()
        guard status == .connected, !busy, !updating,
              let session = manager?.connection as? NETunnelProviderSession else { return }
        let previousUnknown = updateOutcome == .unknown
        guard let profile = try? Self.profile(for: node) else {
            updateOutcome = previousUnknown ? .unknown : .rejected
            return
        }
        let id = UUID()
        updateID = id
        updating = true
        updateOutcome = nil
        defer {
            if updateID == id {
                updateID = nil
                updating = false
                pendingReply = nil
            }
        }
        let current = await send(LabContract.revisionRequest, to: session)
        guard updateID == id else { return }
        guard let revision = LabContract.readRevision(current),
              let message = LabContract.replace(revision: revision, mode: mode.engineValue, profile: profile) else {
            updateOutcome = previousUnknown ? .unknown : .unavailable
            return
        }
        let acknowledgment = await send(message, to: session)
        guard updateID == id else { return }
        if acknowledgment == LabContract.accepted { updateOutcome = .applied }
        else if acknowledgment == LabContract.rejected && !previousUnknown { updateOutcome = .rejected }
        else { updateOutcome = .unknown }
    }

    func draftChanged() {
        if updateOutcome != .unknown { updateOutcome = nil }
    }

    private static func profile(for node: NodeProfile) throws -> Data {
        // The provider and packet engine enforce the only routable target.
        let profile = try CoreConfig.makePacketProfile(nodes: [node])
        guard (1...LabContract.maximumProfile).contains(profile.count) else { throw LabContract.Failure.invalidRequest }
        return profile
    }

    private func invalidateUpdate() {
        updateID = nil
        updating = false
        updateOutcome = nil
        let reply = pendingReply
        pendingReply = nil
        reply?.finish(nil)
    }

    private func invalidateTarget() {
        targetReadID = nil
        readingTarget = false
        liveTarget = nil
        let reply = targetReply
        targetReply = nil
        reply?.finish(nil)
    }

    private func send(_ message: Data, to session: NETunnelProviderSession, forTarget: Bool = false) async -> Data? {
        await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            // Target readback and the two-step node update can overlap.
            if forTarget { targetReply = reply } else { pendingReply = reply }
            do {
                try session.sendProviderMessage(message) { [weak reply] data in
                    Task { @MainActor in reply?.finish(data) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5)) { [weak reply] in reply?.finish(nil) }
            } catch {
                reply.finish(nil)
            }
        }
    }

    @MainActor private final class Reply {
        private var continuation: CheckedContinuation<Data?, Never>?

        init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }

        func finish(_ value: Data?) {
            let waiting = continuation
            continuation = nil
            waiting?.resume(returning: value)
        }
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
