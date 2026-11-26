import Foundation

@main enum LabContractChecks {
    static func main() {
        func packet(source: [UInt8], target: [UInt8], port: UInt16 = 18080, outgoing: Bool = true) -> Data {
            var data = Data([0x45, 0, 0, 40, 0, 0, 0x40, 0, 64, 6, 0, 0])
            data.append(contentsOf: source + target)
            let local: [UInt8] = [0xC0, 0x00]
            let fixture = [UInt8(port >> 8), UInt8(truncatingIfNeeded: port)]
            data.append(contentsOf: outgoing ? local + fixture : fixture + local)
            data.append(contentsOf: Array(repeating: 0, count: 16))
            data[32] = 0x50
            return data
        }
        let device: [UInt8] = [198, 18, 0, 1]
        let demo = LabContract.demoTarget
        let target = demo.bytes
        func accepts(_ data: Data, fromProvider: Bool) -> Bool {
            LabContract.accepts(data, target: demo, fromProvider: fromProvider)
        }
        let request = packet(source: device, target: target)
        let response = packet(source: target, target: device, outgoing: false)
        precondition(accepts(request, fromProvider: false))
        precondition(accepts(response, fromProvider: true))
        precondition(!accepts(response, fromProvider: false))
        precondition(!accepts(request, fromProvider: true))
        precondition(!accepts(packet(source: device, target: [198, 51, 100, 43]), fromProvider: false))
        precondition(!accepts(packet(source: [192, 0, 2, 10], target: target), fromProvider: false))
        precondition(!accepts(Data(request.dropLast()), fromProvider: false))
        var invalid = request
        invalid[0] = 0x60
        precondition(!accepts(invalid, fromProvider: false))
        invalid[0] = 0x4F
        precondition(!accepts(invalid, fromProvider: false))
        invalid[0] = 0x45
        invalid[3] = 39
        precondition(!accepts(invalid, fromProvider: false))
        invalid = request
        invalid[23] = 0xA1
        precondition(!accepts(invalid, fromProvider: false))
        invalid = request
        invalid[6] = 0x20
        precondition(!accepts(invalid, fromProvider: false))
        invalid = request
        invalid[9] = 17
        precondition(!accepts(invalid, fromProvider: false))
        invalid = request
        invalid[32] = 0x10
        precondition(!accepts(invalid, fromProvider: false))

        let custom = LabContract.Target(address: "203.0.113.37", port: "40443")!
        precondition(custom.encodedAddress == 0xCB007125)
        let customRequest = packet(source: device, target: custom.bytes, port: custom.port)
        let customReply = packet(source: custom.bytes, target: device, port: custom.port, outgoing: false)
        precondition(LabContract.accepts(customRequest, target: custom, fromProvider: false))
        precondition(LabContract.accepts(customReply, target: custom, fromProvider: true))
        precondition(!LabContract.accepts(customReply, target: custom, fromProvider: false))
        precondition(!LabContract.accepts(request, target: custom, fromProvider: false))
        precondition(!LabContract.accepts(packet(source: device, target: custom.bytes), target: custom, fromProvider: false))
        precondition(!accepts(customRequest, fromProvider: false))
        for address in ["0.1.2.3", "127.0.0.1", "169.254.1.1", "198.18.0.1", "198.18.0.2",
                        "224.0.0.1", "240.1.2.3", "2001:db8::1", "example.invalid", "192.0.2.01", "192..2.1"] {
            precondition(LabContract.Target(address: address, port: "443") == nil)
        }
        for port in ["0", "65536", "-1", "+1", " 80", "080", "８０", ""] {
            precondition(LabContract.Target(address: "203.0.113.37", port: port) == nil)
        }
        precondition(LabContract.Target(address: "10.20.30.40", port: "65535") != nil)
        if case .readTarget? = LabContract.command(LabContract.targetRequest) {} else {
            preconditionFailure("Target request did not round trip")
        }
        let encodedTarget = LabContract.targetReply(custom)
        precondition(LabContract.readTarget(encodedTarget) == custom)
        precondition(LabContract.readTarget(encodedTarget.dropLast()) == nil)
        precondition(LabContract.readTarget(LabContract.targetRequest) == nil)
        precondition(LabContract.command(encodedTarget) == nil)
        var invalidTarget = encodedTarget
        invalidTarget[invalidTarget.count - 2] = 0
        invalidTarget[invalidTarget.count - 1] = 0
        precondition(LabContract.readTarget(invalidTarget) == nil)

        let revision = LabContract.revision()
        let payload = Data(repeating: 0x7B, count: LabContract.maximumProfile)
        let message = LabContract.replace(revision: revision, mode: 1, profile: payload)!
        if case let .replace(decoded, mode, profile)? = LabContract.command(message) {
            precondition(decoded == revision && mode == 1 && profile == payload)
        } else {
            preconditionFailure("Replacement request did not round trip")
        }
        if case .readRevision? = LabContract.command(LabContract.revisionRequest) {} else {
            preconditionFailure("Revision request did not round trip")
        }
        precondition(LabContract.readRevision(LabContract.revisionReply(revision)) == revision)
        precondition(LabContract.readRevision(LabContract.accepted) == nil)
        precondition(LabContract.readRevision(LabContract.revisionReply(Data(repeating: 0, count: revision.count))) == nil)
        precondition(LabContract.replace(revision: revision, mode: 2, profile: payload) == nil)
        precondition(LabContract.replace(revision: revision, mode: 0, profile: Data()) == nil)
        precondition(LabContract.command(message + Data([0])) == nil)
        precondition(LabContract.command(Data(message.dropLast(payload.count))) == nil)
        invalid = message
        invalid[3] = 2
        precondition(LabContract.command(invalid) == nil)
        invalid = message
        invalid[5] = 2
        precondition(LabContract.command(invalid) == nil)
        invalid = message
        invalid[6] = 0
        precondition(LabContract.command(invalid) == nil)

        var gate = LabContract.RevisionGate()
        let initial = gate.current
        precondition(!gate.apply(expected: revision) { preconditionFailure("Stale request reached the engine") })
        precondition(!gate.apply(expected: initial) { false })
        precondition(gate.current == initial)
        precondition(gate.apply(expected: initial) { true })
        precondition(gate.current != initial)
        precondition(!gate.apply(expected: initial) { preconditionFailure("Replayed request reached the engine") })
        let old = gate.current
        gate.reset()
        precondition(!gate.apply(expected: old) { preconditionFailure("Old session request reached the engine") })
        print("CLAY Tunnel Lab packet scope and update wire format passed")
    }
}
