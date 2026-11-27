import Darwin
import Foundation

// Shared by the app and provider. Only one explicitly chosen IP destination
// is routed to the extension; other destinations stay on their usual routes.
enum LabContract {
    static let demoTarget = Target(address: "198.51.100.42", port: "18080")!
    static let demoTarget6 = Target(address: "2001:db8::42", port: "18080")!
    static let interfaceAddress = "198.18.0.1"
    static let remoteAddress = "198.18.0.2"
    static let interfaceAddress6 = "fdfe:dcba:9876::1"
    static let remoteAddress6 = "fdfe:dcba:9876::2"
    static let hostPrefix6: NSNumber = 128
    private static let device4: [UInt8] = [198, 18, 0, 1]
    private static let device6 = parseIPv6(interfaceAddress6)!
    static let hostMask = "255.255.255.255"
    static let mtu = 1500
    static let maximumProfile = 128 * 1024
    static let profileKey = "CLAY.probe.profile"
    static let modeKey = "CLAY.probe.mode"
    static let addressKey = "CLAY.target.address"
    static let portKey = "CLAY.target.port"
    static let probe = Data("CLAY-VPN-PROBE/1".utf8)
    static let response = Data("CLAY-LAB-OK/1".utf8)

    private static let wirePrefix = Data([0x43, 0x4C, 0x59, 1])
    static let revisionRequest = wirePrefix + Data([0])
    private static let replacePrefix = wirePrefix + Data([1])
    private static let revisionPrefix = wirePrefix + Data([2])
    static let accepted = wirePrefix + Data([3])
    static let rejected = wirePrefix + Data([4])
    static let targetRequest = wirePrefix + Data([5])
    private static let targetPrefix = wirePrefix + Data([6])
    private static let revisionLength = 36

    enum Command {
        case readRevision
        case readTarget
        case replace(Data, Int32, Data) // revision, mode, profile
    }

    struct Target: Equatable {
        let bytes: [UInt8]
        let port: UInt16
        var family: Int32 { bytes.count == 4 ? AF_INET : AF_INET6 }
        var isDemo: Bool { self == LabContract.demoTarget || self == LabContract.demoTarget6 }
        var displayEndpoint: String { family == AF_INET ? "\(address):\(port)" : "[\(address)]:\(port)" }
        var address: String {
            if family == AF_INET { return bytes.map(String.init).joined(separator: ".") }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return bytes.withUnsafeBytes { raw in
                guard inet_ntop(AF_INET6, raw.baseAddress, &text, socklen_t(INET6_ADDRSTRLEN)) != nil else { return "" }
                return String(decoding: text.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            }
        }

        init?(address: String, port: String) {
            guard (1...5).contains(port.utf8.count),
                  port.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt16(port),
                  String(number) == port else { return nil }
            if address.contains(":") {
                guard let octets = LabContract.parseIPv6(address) else { return nil }
                self.init(bytes: octets, port: number)
            } else {
                guard (7...15).contains(address.utf8.count) else { return nil }
                let fields = address.split(separator: ".", omittingEmptySubsequences: false)
                guard fields.count == 4 else { return nil }
                let octets = fields.compactMap { field -> UInt8? in
                    guard let octet = UInt8(field), String(octet) == field else { return nil }
                    return octet
                }
                self.init(bytes: octets, port: number)
            }
        }

        fileprivate init?(bytes: [UInt8], port: UInt16) {
            guard port > 0 else { return nil }
            switch bytes.count {
            case 4:
                guard (1...223).contains(bytes[0]), bytes[0] != 127, !(bytes[0] == 169 && bytes[1] == 254),
                      !(bytes.starts(with: LabContract.device4.prefix(3)) && bytes[3] < 4) else { return nil }
            case 16:
                // Exclude IPv4-compatible/mapped, multicast, link-local and the Lab's own subnet.
                let zero = bytes.prefix(10).allSatisfy { $0 == 0 }
                guard !(zero && ((bytes[10] == 0 && bytes[11] == 0) || (bytes[10] == 255 && bytes[11] == 255))),
                      bytes[0] != 255, !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80),
                      !(bytes.starts(with: LabContract.device6.prefix(15)) && bytes[15] & 0xfc == 0) else { return nil }
            default: return nil
            }
            self.bytes = bytes
            self.port = port
        }
    }

    private static func parseIPv6(_ text: String) -> [UInt8]? {
        guard (2...45).contains(text.utf8.count), text.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 46
        }) else { return nil }
        var raw = in6_addr()
        guard inet_pton(AF_INET6, text, &raw) == 1 else { return nil }
        return withUnsafeBytes(of: raw) { Array($0) }
    }

    static func targetReply(_ target: Target) -> Data {
        targetPrefix + Data(target.bytes + [UInt8(target.port >> 8), UInt8(truncatingIfNeeded: target.port)])
    }

    static func readTarget(_ reply: Data?) -> Target? {
        guard let reply, [6, 18].contains(reply.count - targetPrefix.count), reply.starts(with: targetPrefix) else { return nil }
        let data = Array(reply.dropFirst(targetPrefix.count))
        let last = data.count - 1
        return Target(bytes: Array(data.dropLast(2)), port: UInt16(data[last - 1]) << 8 | UInt16(data[last]))
    }

    static func revision() -> Data { Data(UUID().uuidString.utf8) }

    // The provider owns this gate on its serial command queue. Check the
    // revision before handling credentials; rotate it only on a confirmed swap.
    struct RevisionGate {
        private(set) var current = LabContract.revision()

        mutating func reset() { current = LabContract.revision() }

        mutating func apply(expected: Data, replacing: () -> Bool) -> Bool {
            guard expected == current, replacing() else { return false }
            reset()
            return true
        }
    }

    static func revisionReply(_ revision: Data) -> Data { revisionPrefix + revision }

    static func readRevision(_ reply: Data?) -> Data? {
        guard let reply, reply.count == revisionPrefix.count + revisionLength,
              reply.starts(with: revisionPrefix) else { return nil }
        let revision = Data(reply.dropFirst(revisionPrefix.count))
        guard validRevision(revision) else { return nil }
        return revision
    }

    static func replace(revision: Data, mode: Int32, profile: Data) -> Data? {
        guard validRevision(revision), [0, 1].contains(mode),
              (1...maximumProfile).contains(profile.count) else { return nil }
        return replacePrefix + Data([UInt8(mode)]) + revision + profile
    }

    static func command(_ message: Data) -> Command? {
        if message == revisionRequest { return .readRevision }
        if message == targetRequest { return .readTarget }
        let header = replacePrefix.count + 1 + revisionLength
        guard (header + 1...header + maximumProfile).contains(message.count),
              message.starts(with: replacePrefix) else { return nil }
        let body = message.dropFirst(replacePrefix.count)
        guard let mode = body.first, mode <= 1 else { return nil }
        let payload = body.dropFirst()
        let revision = Data(payload.prefix(revisionLength))
        guard validRevision(revision) else { return nil }
        return .replace(revision, Int32(mode), Data(payload.dropFirst(revisionLength)))
    }

    private static func validRevision(_ revision: Data) -> Bool {
        revision.count == revisionLength && String(data: revision, encoding: .utf8).flatMap(UUID.init(uuidString:)) != nil
    }

    static func accepts(_ data: Data, target: Target, fromProvider: Bool) -> Bool {
        guard (40...mtu).contains(data.count) else { return false }
        return data.withUnsafeBytes { bytes in
            let header: Int, source: Range<Int>, destination: Range<Int>, device: [UInt8]
            switch (target.family, bytes[0] >> 4) {
            case (AF_INET, 4):
                header = Int(bytes[0] & 15) * 4
                let fragment = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
                guard header >= 20, fragment & 0x3FFF == 0, bytes[9] == 6,
                      (Int(bytes[2]) << 8 | Int(bytes[3])) == bytes.count else { return false }
                (source, destination, device) = (12..<16, 16..<20, device4)
            case (AF_INET6, 6):
                header = 40
                // TCP must follow the base header. Extension headers and fragments are outside the Lab.
                guard bytes[6] == 6, (Int(bytes[4]) << 8 | Int(bytes[5])) == bytes.count - header else { return false }
                (source, destination, device) = (8..<24, 24..<40, device6)
            default: return false
            }
            guard header + 20 <= bytes.count else { return false }
            let portOffset = header + (fromProvider ? 0 : 2)
            let tcpHeader = Int(bytes[header + 12] >> 4) * 4
            guard tcpHeader >= 20, header + tcpHeader <= bytes.count,
                  UInt16(bytes[portOffset]) << 8 | UInt16(bytes[portOffset + 1]) == target.port else { return false }
            return bytes[source].elementsEqual(fromProvider ? target.bytes : device) &&
                bytes[destination].elementsEqual(fromProvider ? device : target.bytes)
        }
    }

    enum Failure: Int, Error, CustomNSError {
        case invalidRequest = 1, busy, setup, cancelled, engineEnded, packetWriteFailed

        static let errorDomain = "CLAY.TunnelLab"
        var errorCode: Int { rawValue }
    }
}
