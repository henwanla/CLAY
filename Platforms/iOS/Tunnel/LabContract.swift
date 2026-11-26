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
