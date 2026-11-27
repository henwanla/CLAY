import Foundation

public enum SessionError: String, Error {
    case engineMissing, noNode, portsUnavailable, setupFailed, launchFailed, exitedDuringStart, controlUnavailable, selectionFailed, probeFailed
    case telemetryUnavailable, closeConnectionsFailed, engineChanged, routingFailed, countryDataUnavailable
}

public enum CoreRoutingMode: String, CaseIterable, Identifiable, Sendable {
    case rule, global, direct
    public var id: Self { self }
}

public enum CoreRouteTarget: Codable, Hashable, Sendable {
    case selected, direct, group(UUID)
}

public struct CoreAppRoute: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let includesBundleHelpers: Bool
    public var target: CoreRouteTarget

    public init(id: UUID = UUID(), name: String, path: String, includesBundleHelpers: Bool, target: CoreRouteTarget) {
        self.id = id; self.name = name; self.path = path; self.includesBundleHelpers = includesBundleHelpers; self.target = target
    }

    public var isValid: Bool {
        path.hasPrefix("/") && path == path.trimmingCharacters(in: .whitespacesAndNewlines)
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || ",*?".unicodeScalars.contains($0) }
            && (!includesBundleHelpers || path.lowercased().hasSuffix(".app"))
    }
}

public struct CoreRoutingPlan: Sendable {
    public struct Group: Sendable {
        public let id: UUID
        public let members: [UUID]
        public init(id: UUID, members: [UUID]) { self.id = id; self.members = members }
    }
    public let groups: [Group]
    public let proxyGroup: UUID?
    public let applications: [CoreAppRoute]
    public let bypassMainland: Bool
    public init(groups: [Group] = [], proxyGroup: UUID? = nil, applications: [CoreAppRoute] = [], bypassMainland: Bool = false) {
        self.groups = groups; self.proxyGroup = proxyGroup; self.applications = applications; self.bypassMainland = bypassMainland
    }
    public static func name(of id: UUID) -> String { "group-" + id.uuidString.lowercased() }
}

public enum CoreConfig {
    /// Generates the private configuration consumed by the local engine. The result contains credentials.
    public static func make(nodes: [NodeProfile], active: NodeProfile, proxyPort: Int, controlPort: Int, secret: String,
                            mode: CoreRoutingMode = .rule, policy: PACPolicy? = nil,
                            routing: CoreRoutingPlan = .init()) throws -> Data {
        guard let chosen = nodes.first(where: { $0.id == active.id }) else { throw SessionError.noNode }
        guard (1...65535).contains(proxyPort), (1...65535).contains(controlPort), proxyPort != controlPort, !secret.isEmpty else { throw SessionError.setupFailed }
        let ordered = [chosen] + nodes.filter { $0.id != chosen.id }
        let byID = Dictionary(nodes.map { ($0.id, $0.localName) }, uniquingKeysWith: { first, _ in first })
        var groupIDs: Set<UUID> = []
        var groups: [[String: Any]] = [
            ["name": "CLAY", "type": "select", "proxies": ordered.map(\.localName)],
            ["name": "GLOBAL", "type": "select", "proxies": ["CLAY"]]
        ]
        for group in routing.groups {
            let names = group.members.compactMap { byID[$0] }
            if !names.isEmpty, groupIDs.insert(group.id).inserted {
                groups.append(["name": CoreRoutingPlan.name(of: group.id), "type": "select", "proxies": names])
            }
        }
        func target(_ action: CoreRouteTarget) -> String {
            switch action {
            case .selected: return "CLAY"
            case .direct: return "DIRECT"
            case .group(let id): return groupIDs.contains(id) ? CoreRoutingPlan.name(of: id) : "CLAY"
            }
        }
        let appRoutes = routing.applications.filter(\.isValid).map { app in
            app.includesBundleHelpers ? "PROCESS-PATH-WILDCARD,\(app.path)/Contents/*,\(target(app.target))" :
                "PROCESS-PATH,\(app.path),\(target(app.target))"
        }
        let proxy = routing.proxyGroup.map { target(.group($0)) } ?? "CLAY"
        let policyRows: [String]
        if let policy { policyRows = rules(for: policy, proxy: proxy, appRoutes: appRoutes, bypassMainland: routing.bypassMainland) }
        else if !appRoutes.isEmpty || routing.bypassMainland || proxy != "CLAY" {
            policyRows = rules(for: .init(rules: [], defaultDecision: .proxy, bypassLocal: false),
                               proxy: proxy, appRoutes: appRoutes, bypassMainland: routing.bypassMainland)
        } else { policyRows = ["MATCH,CLAY"] }
        return try JSONSerialization.data(withJSONObject: [
            "mixed-port": proxyPort, "bind-address": "127.0.0.1", "allow-lan": false, "mode": mode.rawValue,
            "ipv6": false, "log-level": "silent", "external-controller": "127.0.0.1:\(controlPort)", "secret": secret,
            "geo-auto-update": false, "geodata-mode": routing.bypassMainland,
            "find-process-mode": appRoutes.isEmpty ? "off" : "strict", "profile": ["store-selected": false],
            "tun": ["enable": false],
            "proxies": engineNodes(ordered),
            "proxy-groups": groups,
            "rules": policyRows
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// In-memory input for the experimental packet engine. Contains credentials.
    /// Node indexes are one-based and follow the input order.
    public static func makePacketProfile(nodes: [NodeProfile], policy: PACPolicy? = nil) throws -> Data {
        guard !nodes.isEmpty else { throw SessionError.noNode }
        guard nodes.count <= 100, Set(nodes.map(\.id)).count == nodes.count else { throw SessionError.setupFailed }
        let rows = policy.map { rules(for: $0) } ?? ["MATCH,CLAY"]
        guard rows.count <= 1024 else { throw SessionError.setupFailed }
        let data = try JSONSerialization.data(withJSONObject: ["proxies": engineNodes(nodes), "rules": rows],
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 2 * 1024 * 1024 else { throw SessionError.setupFailed }
        return data
    }

    private static func engineNodes(_ nodes: [NodeProfile]) -> [[String: Any]] {
        nodes.map { node in
            var fields = node.options
            fields["name"] = node.localName
            return fields
        }
    }

    private static func rules(for policy: PACPolicy, proxy: String = "CLAY", appRoutes: [String] = [], bypassMainland: Bool = false) -> [String] {
        func group(_ action: PACDecision) -> String { action == .proxy ? proxy : "DIRECT" }
        var result = ["DOMAIN-SUFFIX,localhost,DIRECT", "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
                      "IP-CIDR,0.0.0.0/32,DIRECT,no-resolve", "IP-CIDR6,::/127,DIRECT,no-resolve"]
        result += appRoutes
        for rule in policy.rules {
            let action = group(rule.decision)
            if rule.kind == .domain, PACTarget.parseIPv4(rule.value, strict: true) != nil {
                result.append("IP-CIDR,\(rule.value)/32,\(action),no-resolve")
            } else if rule.kind == .domain, PACTarget.parseIPv6(rule.value) != nil {
                result.append("IP-CIDR6,\(rule.value)/128,\(action),no-resolve")
            } else {
                result.append("\(rule.kind.rawValue),\(rule.value),\(action)\(rule.kind.isCIDR ? ",no-resolve" : "")")
            }
        }
        if policy.bypassLocal {
            result += ["DOMAIN-SUFFIX,local,DIRECT", "DOMAIN-REGEX,^[^.]+$,DIRECT"]
            result += ["10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16"]
                .map { "IP-CIDR,\($0),DIRECT,no-resolve" }
            result += ["fc00::/7", "fe80::/10"].map { "IP-CIDR6,\($0),DIRECT,no-resolve" }
        }
        // Match known destination IPs without doing a local DNS lookup for an
        // otherwise proxied hostname merely to decide whether it is mainland.
        if bypassMainland { result += ["DOMAIN-SUFFIX,cn,DIRECT", "GEOIP,CN,DIRECT,no-resolve"] }
        result.append("MATCH,\(group(policy.defaultDecision))")
        return result
    }
}
