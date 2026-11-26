import Foundation

// Shared by the test app and provider. Only this documentation IPv4 address
// is routed to the extension; the app's ordinary browsing stays on its network.
enum LabContract {
    static let destination = "198.51.100.42"
    static let port: UInt16 = 18080
    static let interfaceAddress = "198.18.0.1"
    static let remoteAddress = "198.18.0.2"
    static let hostMask = "255.255.255.255"
    static let mtu = 1500
    static let maximumProfile = 128 * 1024
    static let profileKey = "CLAY.probe.profile"
    static let modeKey = "CLAY.probe.mode"
    static let probe = Data("CLAY-VPN-PROBE/1".utf8)
    static let response = Data("CLAY-LAB-OK/1".utf8)

    private static let wirePrefix = Data([0x43, 0x4C, 0x59, 1])
    static let revisionRequest = wirePrefix + Data([0])
    private static let replacePrefix = wirePrefix + Data([1])
    private static let revisionPrefix = wirePrefix + Data([2])
    static let accepted = wirePrefix + Data([3])
    static let rejected = wirePrefix + Data([4])
    private static let revisionLength = 36

    enum Command {
        case readRevision
        case replace(Data, Int32, Data) // revision, mode, profile
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

    static func accepts(_ data: Data, fromProvider: Bool) -> Bool {
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
                  UInt16(bytes[portOffset]) << 8 | UInt16(bytes[portOffset + 1]) == port else { return false }
            let source: [UInt8] = fromProvider ? [198, 51, 100, 42] : [198, 18, 0, 1]
            let target: [UInt8] = fromProvider ? [198, 18, 0, 1] : [198, 51, 100, 42]
            return bytes[12..<16].elementsEqual(source) && bytes[16..<20].elementsEqual(target)
        }
    }

    enum Failure: Int, Error, CustomNSError {
        case invalidRequest = 1, busy, setup, cancelled, engineEnded, packetWriteFailed

        static let errorDomain = "CLAY.TunnelLab"
        var errorCode: Int { rawValue }
    }
}
