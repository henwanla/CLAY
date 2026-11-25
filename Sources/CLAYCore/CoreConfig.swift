import Foundation

public enum SessionError: String, Error {
    case engineMissing, noNode, portsUnavailable, setupFailed, launchFailed, exitedDuringStart, controlUnavailable, selectionFailed, probeFailed
    case telemetryUnavailable, closeConnectionsFailed, engineChanged, routingFailed
}

public enum CoreRoutingMode: String, CaseIterable, Identifiable, Sendable {
    case rule, global, direct
    public var id: Self { self }
}

public enum CoreConfig {
    /// Generates the private configuration consumed by the local engine. The result contains credentials.
    public static func make(nodes: [NodeProfile], active: NodeProfile, proxyPort: Int, controlPort: Int, secret: String,
                            mode: CoreRoutingMode = .rule, policy: PACPolicy? = nil) throws -> Data {
        guard let chosen = nodes.first(where: { $0.id == active.id }) else { throw SessionError.noNode }
        guard (1...65535).contains(proxyPort), (1...65535).contains(controlPort), proxyPort != controlPort, !secret.isEmpty else { throw SessionError.setupFailed }
        let ordered = [chosen] + nodes.filter { $0.id != chosen.id }
        return try JSONSerialization.data(withJSONObject: [
            "mixed-port": proxyPort, "bind-address": "127.0.0.1", "allow-lan": false, "mode": mode.rawValue,
            "ipv6": false, "log-level": "silent", "external-controller": "127.0.0.1:\(controlPort)", "secret": secret,
            "geo-auto-update": false, "find-process-mode": "off", "profile": ["store-selected": false],
            "tun": ["enable": false],
            "proxies": ordered.map { node in var p = node.options; p["name"] = node.localName; return p },
            "proxy-groups": [
                ["name": "CLAY", "type": "select", "proxies": ordered.map(\.localName)],
                ["name": "GLOBAL", "type": "select", "proxies": ["CLAY"]]
            ],
            "rules": policy.map(rules(for:)) ?? ["MATCH,CLAY"]
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func rules(for policy: PACPolicy) -> [String] {
        func group(_ action: PACDecision) -> String { action == .proxy ? "CLAY" : "DIRECT" }
        var result = ["DOMAIN-SUFFIX,localhost,DIRECT", "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
                      "IP-CIDR,0.0.0.0/32,DIRECT,no-resolve", "IP-CIDR6,::/127,DIRECT,no-resolve"]
        for rule in policy.rules {
            let action = group(rule.decision)
            if rule.kind == .domain, PACTarget.parseIPv4(rule.value, strict: true) != nil {
                result.append("IP-CIDR,\(rule.value)/32,\(action),no-resolve")
            } else if rule.kind == .domain, PACTarget.parseIPv6(rule.value) != nil {
                result.append("IP-CIDR6,\(rule.value)/128,\(action),no-resolve")
            } else {
                result.append("\(rule.kind.rawValue),\(rule.value),\(action)\(rule.kind == .ipCIDR ? ",no-resolve" : "")")
            }
        }
        if policy.bypassLocal {
            result += ["DOMAIN-SUFFIX,local,DIRECT", "DOMAIN-REGEX,^[^.]+$,DIRECT"]
            result += ["10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16"]
                .map { "IP-CIDR,\($0),DIRECT,no-resolve" }
            result += ["fc00::/7", "fe80::/10"].map { "IP-CIDR6,\($0),DIRECT,no-resolve" }
        }
        result.append("MATCH,\(group(policy.defaultDecision))")
        return result
    }
}
