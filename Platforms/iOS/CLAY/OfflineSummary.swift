import CLAYCore

struct OfflineSummary {
    struct ProtocolCount {
        let name: String
        let count: Int
    }

    struct IssueCount {
        let kind: ImportError
        let count: Int
    }

    let accepted: Int
    let protocols: [ProtocolCount]
    let issues: [IssueCount]

    init(_ input: String) {
        let result = ProfileImporter.read(input)
        var byProtocol: [String: Int] = [:]
        for profile in result.profiles {
            // Keep only a controlled display label; node names, addresses and credentials are discarded.
            let name: String
            switch profile.protocolName {
            case "vmess": name = "VMess"
            case "vless": name = "VLESS"
            case "ss": name = "Shadowsocks"
            case "trojan": name = "Trojan"
            case "hysteria2": name = "Hysteria2"
            default: continue
            }
            byProtocol[name, default: 0] += 1
        }
        accepted = result.profiles.count
        protocols = byProtocol.sorted { $0.key < $1.key }.map { ProtocolCount(name: $0.key, count: $0.value) }
        issues = result.issues.sorted { $0.key.rawValue < $1.key.rawValue }.map { IssueCount(kind: $0.key, count: $0.value) }
    }

    static let example = """
    proxies:
      - name: Sample VLESS
        type: vless
        server: sample.invalid
        port: 443
        uuid: 11111111-1111-4111-8111-111111111111
        tls: true
      - name: Sample unsupported node
        type: socks5
        server: sample.invalid
        port: 1080
    """
}
