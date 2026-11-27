import Darwin
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private typealias StartCompletion = (Error?) -> Void
    private enum State {
        case idle
        case applying(UInt64, LabContract.Target, StartCompletion)
        case running(UInt64, LabContract.Target)
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
                  mode.doubleValue == 0 || mode.doubleValue == 1,
                  let address = options?[LabContract.addressKey] as? String,
                  let port = options?[LabContract.portKey] as? String,
                  let target = LabContract.Target(address: address, port: port),
                  (1...LabContract.maximumProfile).contains(profile.length) else {
                completionHandler(LabContract.Failure.invalidRequest)
                return
            }
            let source = profile.bytes.assumingMemoryBound(to: UInt8.self)
            // Go copies input before returning. Only the chosen node crosses IPC.
            let id = target.bytes.withUnsafeBufferPointer { address in
                clay_engine_start_lab(UnsafeMutablePointer(mutating: source), Int32(profile.length), mode.int32Value,
                                      UnsafeMutablePointer(mutating: address.baseAddress!), Int32(address.count), target.port)
            }
            guard id != 0 else {
                completionHandler(LabContract.Failure.setup)
                return
            }
            self.state = .applying(id, target, completionHandler)
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress:
                target.family == AF_INET ? LabContract.remoteAddress : LabContract.remoteAddress6)
            if target.family == AF_INET {
                let ipv4 = NEIPv4Settings(addresses: [LabContract.interfaceAddress], subnetMasks: [LabContract.hostMask])
                ipv4.includedRoutes = [NEIPv4Route(destinationAddress: target.address, subnetMask: LabContract.hostMask)]
                settings.ipv4Settings = ipv4
            } else {
                let ipv6 = NEIPv6Settings(addresses: [LabContract.interfaceAddress6], networkPrefixLengths: [LabContract.hostPrefix6])
                ipv6.includedRoutes = [NEIPv6Route(destinationAddress: target.address, networkPrefixLength: LabContract.hostPrefix6)]
                settings.ipv6Settings = ipv6
            }
            settings.mtu = NSNumber(value: LabContract.mtu)
            // No default route, DNS override, proxy settings, or routes in the other family.
            self.setTunnelNetworkSettings(settings) { [weak self] error in
                self?.commands.async { [weak self] in self?.finishApplying(id, success: error == nil) }
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Ignore updates for which the caller cannot receive an acknowledgment.
        guard let completionHandler else { return }
        commands.async {
            guard case .running(let id, let target) = self.state,
                  let command = LabContract.command(messageData) else {
                completionHandler(LabContract.rejected)
                return
            }
            switch command {
            case .readRevision:
                completionHandler(LabContract.revisionReply(self.revision.current))
            case .readTarget:
                completionHandler(LabContract.targetReply(target))
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
            case .running(let id, _):
                self.state = .idle
                clay_engine_stop(id)
            case .applying(let id, _, let started):
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
        if case .drainingSettings(let draining) = state, draining == id {
            state = .idle
            return
        }
        guard case .applying(let applying, let target, let completion) = state, applying == id else { return }
        guard success else {
            state = .idle
            clay_engine_stop(id)
            completion(LabContract.Failure.setup)
            return
        }
        revision.reset()
        state = .running(id, target)
        readFromSystem(id)
        readFromEngine(id)
        completion(nil)
    }

    private func target(for id: UInt64) -> LabContract.Target? {
        if case .running(let current, let target) = state, current == id { return target }
        return nil
    }

    private func readFromSystem(_ id: UInt64) {
        guard !systemReadPending else { return }
        systemReadPending = true
        packetFlow.readPackets { [weak self] packets, protocols in
            self?.commands.async { [weak self] in
                guard let self else { return }
                self.systemReadPending = false
                if let target = self.target(for: id) {
                    for (packet, family) in zip(packets, protocols).prefix(64)
                        where family.int32Value == target.family && LabContract.accepts(packet, target: target, fromProvider: false) {
                        packet.withUnsafeBytes { bytes in
                            guard let address = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
                            _ = clay_engine_offer(id, UnsafeMutablePointer(mutating: address), Int32(bytes.count))
                        }
                    }
                }
                if case .running(let current, _) = self.state { self.readFromSystem(current) }
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
                guard let self, let target = self.target(for: id) else { return }
                if count < 0 {
                    self.end(id, because: .engineEnded)
                    return
                }
                if let packet, LabContract.accepts(packet, target: target, fromProvider: true),
                   !self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: target.family)]) {
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
