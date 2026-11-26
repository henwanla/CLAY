import Darwin
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private typealias StartCompletion = (Error?) -> Void
    private enum State {
        case idle
        case applying(UInt64, StartCompletion)
        case running(UInt64)
        case drainingSettings(UInt64)
    }

    private let commands = DispatchQueue(label: "app.clay.lab.provider")
    private let packetReader = DispatchQueue(label: "app.clay.lab.output", qos: .userInitiated)
    private var state: State = .idle // commands only
    private var systemReadPending = false
    private var revision = LabContract.RevisionGate() // commands only

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        commands.async {
            guard case .idle = self.state else {
                completionHandler(LabContract.Failure.busy)
                return
            }
            guard let profile = options?[LabContract.profileKey] as? NSData,
                  let mode = options?[LabContract.modeKey] as? NSNumber,
                  [0, 1].contains(mode.intValue),
                  (1...LabContract.maximumProfile).contains(profile.length) else {
                completionHandler(LabContract.Failure.invalidRequest)
                return
            }
            let source = profile.bytes.assumingMemoryBound(to: UInt8.self)
            // Go copies input before returning. Only the chosen node crosses IPC.
            let id = clay_engine_start_lab(UnsafeMutablePointer(mutating: source), Int32(profile.length), mode.int32Value)
            guard id != 0 else {
                completionHandler(LabContract.Failure.setup)
                return
            }
            self.state = .applying(id, completionHandler)
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: LabContract.remoteAddress)
            let ipv4 = NEIPv4Settings(addresses: [LabContract.interfaceAddress], subnetMasks: [LabContract.hostMask])
            ipv4.includedRoutes = [NEIPv4Route(destinationAddress: LabContract.destination, subnetMask: LabContract.hostMask)]
            settings.ipv4Settings = ipv4
            settings.mtu = NSNumber(value: LabContract.mtu)
            // No default route, DNS override, proxy settings, or IPv6 routes.
            self.setTunnelNetworkSettings(settings) { [weak self] error in
                self?.commands.async { [weak self] in self?.finishApplying(id, success: error == nil) }
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Ignore updates for which the caller cannot receive an acknowledgment.
        guard let completionHandler else { return }
        commands.async {
            guard case .running(let id) = self.state,
                  let command = LabContract.command(messageData) else {
                completionHandler(LabContract.rejected)
                return
            }
            switch command {
            case .readRevision:
                completionHandler(LabContract.revisionReply(self.revision.current))
            case .replace(let expected, let mode, let profile):
                let applied = self.revision.apply(expected: expected) {
                    profile.withUnsafeBytes { bytes in
                        guard let ptr = bytes.bindMemory(to: UInt8.self).baseAddress else { return false }
                        return clay_engine_replace_lab(id, UnsafeMutablePointer(mutating: ptr), Int32(bytes.count), mode) == 0
                    }
                }
                completionHandler(applied ? LabContract.accepted : LabContract.rejected)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        commands.async {
            switch self.state {
            case .running(let id):
                self.state = .idle
                clay_engine_stop(id)
            case .applying(let id, let started):
                self.state = .drainingSettings(id)
                clay_engine_stop(id)
                started(LabContract.Failure.cancelled)
            case .drainingSettings, .idle:
                break
            }
            completionHandler()
        }
    }

    private func finishApplying(_ id: UInt64, success: Bool) {
        if case .drainingSettings(id) = state {
            state = .idle
            return
        }
        guard case .applying(id, let completion) = state else { return }
        guard success else {
            state = .idle
            clay_engine_stop(id)
            completion(LabContract.Failure.setup)
            return
        }
        revision.reset()
        state = .running(id)
        readFromSystem(id)
        readFromEngine(id)
        completion(nil)
    }

    private func running(_ id: UInt64) -> Bool {
        if case .running(id) = state { return true }
        return false
    }

    private func readFromSystem(_ id: UInt64) {
        guard !systemReadPending else { return }
        systemReadPending = true
        packetFlow.readPackets { [weak self] packets, protocols in
            self?.commands.async { [weak self] in
                guard let self else { return }
                self.systemReadPending = false
                if self.running(id) {
                    for (packet, family) in zip(packets, protocols).prefix(64)
                        where family.int32Value == AF_INET && LabContract.accepts(packet, fromProvider: false) {
                        packet.withUnsafeBytes { bytes in
                            guard let address = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
                            _ = clay_engine_offer(id, UnsafeMutablePointer(mutating: address), Int32(bytes.count))
                        }
                    }
                }
                if case .running(let current) = self.state { self.readFromSystem(current) }
            }
        }
    }

    private func readFromEngine(_ id: UInt64) {
        packetReader.async { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: LabContract.mtu)
            let count = buffer.withUnsafeMutableBufferPointer { bytes in
                clay_engine_read(id, bytes.baseAddress!, Int32(bytes.count), 250)
            }
            let packet: Data? = count > 0 && count <= buffer.count ? Data(buffer.prefix(Int(count))) : nil
            self.commands.async { [weak self] in
                guard let self, self.running(id) else { return }
                if count < 0 {
                    self.end(id, because: .engineEnded)
                    return
                }
                if let packet, LabContract.accepts(packet, fromProvider: true),
                   !self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)]) {
                    self.end(id, because: .packetWriteFailed)
                    return
                }
                // At most one read and one packet delivery are pending. Old
                // callbacks stop here when their Go session ID is no longer live.
                self.readFromEngine(id)
            }
        }
    }

    private func end(_ id: UInt64, because error: LabContract.Failure) {
        state = .idle
        clay_engine_stop(id)
        cancelTunnelWithError(error)
    }
}
