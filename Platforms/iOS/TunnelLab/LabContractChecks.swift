import Foundation

@main enum LabContractChecks {
    static func main() {
        func packet(source: [UInt8], target: [UInt8], outgoing: Bool = true) -> Data {
            var data = Data([0x45, 0, 0, 40, 0, 0, 0x40, 0, 64, 6, 0, 0])
            data.append(contentsOf: source + target)
            let local: [UInt8] = [0xC0, 0x00]
            let fixture: [UInt8] = [0x46, 0xA0]
            data.append(contentsOf: outgoing ? local + fixture : fixture + local)
            data.append(contentsOf: Array(repeating: 0, count: 16))
            data[32] = 0x50
            return data
        }
        let device: [UInt8] = [198, 18, 0, 1]
        let target: [UInt8] = [198, 51, 100, 42]
        let request = packet(source: device, target: target)
        let response = packet(source: target, target: device, outgoing: false)
        precondition(LabContract.accepts(request, fromProvider: false))
        precondition(LabContract.accepts(response, fromProvider: true))
        precondition(!LabContract.accepts(response, fromProvider: false))
        precondition(!LabContract.accepts(request, fromProvider: true))
        precondition(!LabContract.accepts(packet(source: device, target: [198, 51, 100, 43]), fromProvider: false))
        precondition(!LabContract.accepts(packet(source: [192, 0, 2, 10], target: target), fromProvider: false))
        precondition(!LabContract.accepts(Data(request.dropLast()), fromProvider: false))
        var invalid = request
        invalid[0] = 0x60
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid[0] = 0x4F
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid[0] = 0x45
        invalid[3] = 39
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid = request
        invalid[23] = 0xA1
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid = request
        invalid[6] = 0x20
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid = request
        invalid[9] = 17
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid = request
        invalid[32] = 0x10
        precondition(!LabContract.accepts(invalid, fromProvider: false))

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
