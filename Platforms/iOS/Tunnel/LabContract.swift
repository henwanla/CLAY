import Foundation

// Shared by the app and provider. Only one explicitly chosen IPv4 destination
// is routed to the extension; other destinations stay on their usual routes.
enum LabContract {
    static let demoTarget = Target(address: "198.51.100.42", port: "18080")!
    static let interfaceAddress = "198.18.0.1"
    static let remoteAddress = "198.18.0.2"
    static let hostMask = "255.255.255.255"
    static let mtu = 1500
    static let maximumProfile = 128 * 1024
    static let profileKey = "CLAY.probe.profile"
    static let modeKey = "CLAY.probe.mode"
    static let addressKey = "CLAY.target.ipv4"
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
        var address: String { bytes.map(String.init).joined(separator: ".") }
        var encodedAddress: UInt32 { bytes.reduce(0) { ($0 << 8) | UInt32($1) } }

        init?(address: String, port: String) {
            guard (7...15).contains(address.utf8.count), (1...5).contains(port.utf8.count),
                  port.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt16(port),
                  String(number) == port else { return nil }
            let fields = address.split(separator: ".", omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            let octets = fields.compactMap { field -> UInt8? in
                guard let octet = UInt8(field), String(octet) == field else { return nil }
                return octet
            }
            self.init(bytes: octets, port: number)
        }

        fileprivate init?(bytes: [UInt8], port: UInt16) {
            guard bytes.count == 4, port > 0, (1...223).contains(bytes[0]), bytes[0] != 127,
                  !(bytes[0] == 169 && bytes[1] == 254),
                  bytes != [198, 18, 0, 1], bytes != [198, 18, 0, 2] else { return nil }
            self.bytes = bytes
            self.port = port
        }
    }

    static func targetReply(_ target: Target) -> Data {
        targetPrefix + Data(target.bytes + [UInt8(target.port >> 8), UInt8(truncatingIfNeeded: target.port)])
    }

    static func readTarget(_ reply: Data?) -> Target? {
        guard let reply, reply.count == targetPrefix.count + 6, reply.starts(with: targetPrefix) else { return nil }
        let data = Array(reply.dropFirst(targetPrefix.count))
        return Target(bytes: Array(data.prefix(4)), port: UInt16(data[4]) << 8 | UInt16(data[5]))
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
            let header = Int(bytes[0] & 15) * 4
            let fragment = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
            guard bytes[0] >> 4 == 4, header >= 20, header + 20 <= bytes.count,
                  fragment & 0x3FFF == 0, bytes[9] == 6, // Unfragmented TCP only.
                  (Int(bytes[2]) << 8 | Int(bytes[3])) == bytes.count else { return false }
            let portOffset = header + (fromProvider ? 0 : 2)
            let tcpHeader = Int(bytes[header + 12] >> 4) * 4
            guard tcpHeader >= 20, header + tcpHeader <= bytes.count,
                  UInt16(bytes[portOffset]) << 8 | UInt16(bytes[portOffset + 1]) == target.port else { return false }
            let device: [UInt8] = [198, 18, 0, 1]
            return bytes[12..<16].elementsEqual(fromProvider ? target.bytes : device) &&
                bytes[16..<20].elementsEqual(fromProvider ? device : target.bytes)
        }
    }

    enum Failure: Int, Error, CustomNSError {
        case invalidRequest = 1, busy, setup, cancelled, engineEnded, packetWriteFailed

        static let errorDomain = "CLAY.TunnelLab"
        var errorCode: Int { rawValue }
    }
}
