import Darwin
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
        func datagram(_ packet: Data, family: Int32) -> Data {
            let header = family == AF_INET ? 20 : 40
            var udp = Data(packet.prefix(header + 8))
            udp.append(contentsOf: [1, 2, 3])
            if family == AF_INET {
                udp[3] = UInt8(udp.count)
                udp[9] = 17
            } else {
                udp[5] = UInt8(udp.count - header)
                udp[6] = 17
            }
            udp[header + 4] = 0
            udp[header + 5] = UInt8(udp.count - header)
            return udp
        }
        let udp4 = datagram(request, family: AF_INET)
        precondition(accepts(udp4, fromProvider: false))
        precondition(accepts(datagram(response, family: AF_INET), fromProvider: true))
        precondition(!accepts(udp4, fromProvider: true))
        precondition(!accepts(datagram(packet(source: device, target: target, port: 443), family: AF_INET), fromProvider: false))
        var brokenUDP = udp4
        brokenUDP[25] = 8 // Claimed UDP length omits payload.
        precondition(!accepts(brokenUDP, fromProvider: false))
        brokenUDP = udp4
        brokenUDP[6] = 0x20
        precondition(!accepts(brokenUDP, fromProvider: false))
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
        precondition(custom.bytes == [203, 0, 113, 37] && custom.family == AF_INET)
        let customRequest = packet(source: device, target: custom.bytes, port: custom.port)
        let customReply = packet(source: custom.bytes, target: device, port: custom.port, outgoing: false)
        precondition(LabContract.accepts(customRequest, target: custom, fromProvider: false))
        precondition(LabContract.accepts(customReply, target: custom, fromProvider: true))
        precondition(!LabContract.accepts(customReply, target: custom, fromProvider: false))
        precondition(!LabContract.accepts(request, target: custom, fromProvider: false))
        precondition(!LabContract.accepts(packet(source: device, target: custom.bytes), target: custom, fromProvider: false))
        precondition(!accepts(customRequest, fromProvider: false))
        for address in ["0.1.2.3", "127.0.0.1", "169.254.1.1", "198.18.0.1", "198.18.0.2", "198.18.0.3",
                        "224.0.0.1", "240.1.2.3", "example.invalid", "192.0.2.01", "192..2.1", "::", "::1",
                        "ff02::1", "fe80::1", "2001:db8::1%en0", "[2001:db8::1]", "fdfe:dcba:9876::3",
                        "::ffff:192.0.2.1", "::192.0.2.1", "2001::db8::1", "2001:db8::42\0ignored"] {
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

        let demo6 = LabContract.demoTarget6
        let custom6 = LabContract.Target(address: "2001:0DB8:0:0:0:0:0:37", port: "40443")!
        precondition(custom6.family == AF_INET6 && custom6.address == "2001:db8::37" && !custom6.isDemo)
        precondition(demo6.isDemo && demo6.displayEndpoint == "[2001:db8::42]:18080")
        precondition(LabContract.Target(address: "fd00::beef", port: "65535") != nil)
        precondition(LabContract.readTarget(LabContract.targetReply(custom6)) == custom6)
        precondition(LabContract.readTarget(LabContract.targetReply(custom6).dropLast()) == nil)
        precondition(!LabContract.accepts(request, target: custom6, fromProvider: false))
        let device6: [UInt8] = [0xfd, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        func packet6(_ source: [UInt8], _ dest: [UInt8], port: UInt16 = 40443, outgoing: Bool = true) -> Data {
            let tcp = packet(source: device, target: target, port: port, outgoing: outgoing).dropFirst(20)
            return Data([0x60, 0, 0, 0, 0, 20, 6, 64] + source + dest) + tcp
        }
        let request6 = packet6(device6, custom6.bytes)
        let response6 = packet6(custom6.bytes, device6, outgoing: false)
        func accepts6(_ data: Data, output: Bool = false) -> Bool {
            LabContract.accepts(data, target: custom6, fromProvider: output)
        }
        precondition(accepts6(request6) && accepts6(response6, output: true))
        precondition(!accepts6(response6) && !accepts6(request6, output: true))
        precondition(!accepts6(packet6(device6, demo6.bytes)))
        precondition(!accepts6(packet6(demo6.bytes, custom6.bytes)))
        precondition(!accepts6(packet6(device6, custom6.bytes, port: 443)))
        precondition(!accepts6(request6.dropLast()))
        let udp6 = datagram(request6, family: AF_INET6)
        precondition(accepts6(udp6) && accepts6(datagram(response6, family: AF_INET6), output: true))
        precondition(!accepts6(udp6, output: true) && !accepts6(udp6.dropLast()))
        precondition(!accepts6(datagram(packet6(device6, demo6.bytes), family: AF_INET6)))
        brokenUDP = udp6
        brokenUDP[40] = 0
        brokenUDP[41] = 0
        precondition(!accepts6(brokenUDP))
        var invalid6 = request6
        for nextHeader: UInt8 in [0, 17, 43, 44, 60] { // TCP-shaped data cannot claim UDP or an extension header.
            invalid6[6] = nextHeader
            precondition(!accepts6(invalid6))
        }
        invalid6 = request6
        invalid6[52] = 0xF0
        precondition(!accepts6(invalid6))

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
