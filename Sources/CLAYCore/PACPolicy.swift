import Foundation

public enum PACDecision: String, CaseIterable, Codable, Sendable {
    case direct = "DIRECT"
    case proxy = "PROXY"
}

public enum PACError: LocalizedError, Equatable, Sendable {
    case invalidHost
    case invalidCIDR
    case invalidKeyword
    case invalidPort
    case invalidRuleLine(Int, String)
    case cannotServe

    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "请输入有效的域名、IP 地址或完整 URL。"
        case .invalidCIDR: return "IP 网段格式无效，例如 192.0.2.0/24 或 2001:db8::/32。"
        case .invalidKeyword: return "请输入由字母、数字、点、连字符或下划线组成的域名关键词。"
        case .invalidPort: return "本机代理端口无效。"
        case .invalidRuleLine(let line, let reason): return "第 \(line) 行：\(reason)"
        case .cannotServe: return "无法启动本机 PAC 服务。"
        }
    }
}

public struct PACRule: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case domain = "DOMAIN"
        case domainSuffix = "DOMAIN-SUFFIX"
        case domainKeyword = "DOMAIN-KEYWORD"
        case ipCIDR = "IP-CIDR"
        case ipCIDR6 = "IP-CIDR6"

        var isCIDR: Bool { self == .ipCIDR || self == .ipCIDR6 }
    }

    public let id: UUID
    public let kind: Kind
    public let value: String
    public let decision: PACDecision

    public init(id: UUID = UUID(), kind: Kind, value: String, decision: PACDecision) throws {
        self.id = id
        self.kind = kind
        self.decision = decision
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .domain:
            guard let target = PACTarget(input) else { throw PACError.invalidHost }
            self.value = target.host
        case .domainSuffix:
            let suffix = input.hasPrefix("*.") ? String(input.dropFirst(2)) : input.hasPrefix(".") ? String(input.dropFirst()) : input
            guard let target = PACTarget(suffix), target.isDomain else { throw PACError.invalidHost }
            self.value = target.host
        case .domainKeyword:
            let keyword = input.lowercased()
            guard !keyword.isEmpty, keyword.utf8.count <= 253,
                  keyword.utf8.allSatisfy({ PACTarget.isDomainCharacter($0) || $0 == 46 }) else {
                throw PACError.invalidKeyword
            }
            self.value = keyword
        case .ipCIDR:
            guard let cidr = PACIPv4CIDR(input) else { throw PACError.invalidCIDR }
            self.value = cidr.text
        case .ipCIDR6:
            guard let cidr = PACIPv6CIDR(input) else { throw PACError.invalidCIDR }
            self.value = cidr.text
        }
    }

    private enum CodingKeys: String, CodingKey { case id, kind, value, decision }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), kind: c.decode(Kind.self, forKey: .kind),
                      value: c.decode(String.self, forKey: .value), decision: c.decode(PACDecision.self, forKey: .decision))
    }

    public var exportLine: String { "\(kind.rawValue),\(value),\(decision.rawValue)" }

    public var requiresHostname: Bool {
        switch kind {
        case .domain: return PACTarget(value)?.isDomain == true
        case .domainSuffix, .domainKeyword: return true
        case .ipCIDR, .ipCIDR6: return false
        }
    }

    fileprivate func matches(_ target: PACTarget) -> Bool {
        switch kind {
        case .domain: return target.host == value
        case .domainSuffix: return target.isDomain && (target.host == value || target.host.hasSuffix("." + value))
        case .domainKeyword: return target.isDomain && target.host.contains(value)
        case .ipCIDR:
            guard let ip = target.ipv4, let cidr = PACIPv4CIDR(value) else { return false }
            return ip & cidr.mask == cidr.network
        case .ipCIDR6:
            guard let ip = target.ipv6, let cidr = PACIPv6CIDR(value) else { return false }
            return cidr.contains(ip)
        }
    }
}

public struct PACMatch: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case loopback, local, rule, fallback }
    public let decision: PACDecision
    public let reason: Reason
    public let ruleIndex: Int?
}

public struct PACPolicy: Equatable, Codable, Sendable {
    public var rules: [PACRule]
    public var defaultDecision: PACDecision
    public var bypassLocal: Bool

    public init(rules: [PACRule], defaultDecision: PACDecision, bypassLocal: Bool) {
        self.rules = rules
        self.defaultDecision = defaultDecision
        self.bypassLocal = bypassLocal
    }

    public static let standard = Self(rules: [], defaultDecision: .proxy, bypassLocal: true)

    // The order mirrors FindProxyForURL: loopback protection, explicit rules,
    // optional local fallback, then the default action.
    public func evaluate(_ input: String) throws -> PACMatch {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.contains("://") {
            guard let parsed = URL(string: host)?.host, !parsed.isEmpty else { throw PACError.invalidHost }
            host = parsed
        }
        guard let target = PACTarget(host) else { throw PACError.invalidHost }
        if target.isLoopback { return PACMatch(decision: .direct, reason: .loopback, ruleIndex: nil) }
        if let index = rules.firstIndex(where: { $0.matches(target) }) {
            return PACMatch(decision: rules[index].decision, reason: .rule, ruleIndex: index)
        }
        if bypassLocal, target.isLocal { return PACMatch(decision: .direct, reason: .local, ruleIndex: nil) }
        return PACMatch(decision: defaultDecision, reason: .fallback, ruleIndex: nil)
    }

    /// Imports the PAC-compatible subset of Clash rule rows. All rows must be
    /// valid before any rule is appended. CIDR rules always skip DNS lookups.
    public static func importRules(_ text: String) throws -> [PACRule] {
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var result: [PACRule] = []
        for (offset, raw) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }
            let columns = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let lineNumber = offset + 1
            if columns[0].uppercased() == "MATCH" {
                throw PACError.invalidRuleLine(lineNumber, "MATCH 请在「未命中规则」中设置。")
            }
            guard let kind = PACRule.Kind(rawValue: columns[0].uppercased()) else {
                throw PACError.invalidRuleLine(lineNumber, "PAC 不支持这种规则类型。")
            }
            guard columns.count == 3 || (columns.count == 4 && kind.isCIDR && columns[3].lowercased() == "no-resolve"),
                  let decision = PACDecision(rawValue: columns[2].uppercased()) else {
                throw PACError.invalidRuleLine(lineNumber, "请使用「类型,目标,DIRECT 或 PROXY」。")
            }
            do { result.append(try PACRule(kind: kind, value: columns[1], decision: decision)) }
            catch { throw PACError.invalidRuleLine(lineNumber, error.localizedDescription) }
        }
        return result
    }

    public func makeScript(proxyPort: Int) throws -> String {
        guard (1...65535).contains(proxyPort) else { throw PACError.invalidPort }
        let rules: [[Any]] = rules.map { rule in
            let action = rule.decision == .direct
            if let cidr = rule.kind == .ipCIDR ? PACIPv4CIDR(rule.value) : nil {
                return [rule.kind.rawValue, cidr.network, cidr.mask, action]
            }
            if let cidr = rule.kind == .ipCIDR6 ? PACIPv6CIDR(rule.value) : nil {
                return [rule.kind.rawValue, cidr.network, cidr.prefix, action]
            }
            return [rule.kind.rawValue, rule.value, action]
        }
        // Values are validated and serialized as data, never interpolated as code.
        let serialized = try JSONSerialization.data(withJSONObject: rules)
        return """
        var CLAYRules = \(String(decoding: serialized, as: UTF8.self));
        var CLAYProxy = "PROXY 127.0.0.1:\(proxyPort)";
        var CLAYDefault = \(defaultDecision == .direct ? "true" : "false");
        var CLAYBypassLocal = \(bypassLocal ? "true" : "false");
        \(Self.scriptBody)
        """
    }

    private static let scriptBody = #"""
    function clayIPv4(host, strict) {
        var p = host.split("."), total = 0;
        if (p.length > 4 || (strict && p.length !== 4)) return null;
        for (var i = 0; i < p.length; i++) {
            var t = p[i], n;
            if (/^(0|[1-9][0-9]*)$/.test(t)) n = Number(t);
            else if (!strict && /^0x[0-9a-f]+$/.test(t)) n = parseInt(t.substring(2), 16);
            else if (!strict && /^0[0-7]+$/.test(t)) n = parseInt(t, 8);
            else return null;
            if (i < p.length - 1) {
                if (n > 255) return null;
                total = total * 256 + n;
            } else {
                var base = Math.pow(256, 5 - p.length);
                if (n >= base) return null;
                return total * base + n;
            }
        }
        return null;
    }
    function clayIPv6(host) {
        var scope = host.indexOf("%");
        if (scope >= 0) host = host.substring(0, scope);
        if (host.indexOf(".") >= 0) {
            var end = host.lastIndexOf(":"), v4 = clayIPv4(host.substring(end + 1), true);
            if (v4 === null) return null;
            host = host.substring(0, end + 1) + (v4 >>> 16).toString(16) + ":" + (v4 & 65535).toString(16);
        }
        var sides = host.split("::");
        if (sides.length > 2) return null;
        var a = sides[0] ? sides[0].split(":") : [], b = sides[1] ? sides[1].split(":") : [];
        var fill = 8 - a.length - b.length;
        if ((sides.length === 1 && (fill !== 0 || b.length !== 0)) || (sides.length === 2 && fill < 1)) return null;
        while (fill-- > 0) a.push("0");
        a = a.concat(b);
        for (var i = 0; i < a.length; i++) {
            if (!/^[0-9a-f]{1,4}$/.test(a[i])) return null;
            a[i] = parseInt(a[i], 16);
        }
        return a;
    }
    function clayIPv6Prefix(address, network, remaining) {
        for (var i = 0; remaining > 0; i++, remaining -= 16) {
            var shift = Math.max(0, 16 - remaining);
            if ((address[i] >>> shift) !== (network[i] >>> shift)) return false;
        }
        return true;
    }
    function claySuffix(host, suffix) {
        return host === suffix || host.slice(-(suffix.length + 1)) === "." + suffix;
    }
    function FindProxyForURL(url, host) {
        host = host.toLowerCase();
        if (host.charAt(0) === "[" && host.charAt(host.length - 1) === "]") host = host.slice(1, -1);
        if (host.charAt(host.length - 1) === ".") host = host.slice(0, -1);
        var v6 = host.indexOf(":") < 0 ? null : clayIPv6(host);
        var ip = v6 === null ? clayIPv4(host, false) : null;
        // Mihomo treats IPv4-mapped IPv6 destinations as IPv4 before matching.
        if (v6 !== null && (v6[0] | v6[1] | v6[2] | v6[3] | v6[4]) === 0 && v6[5] === 65535) {
            ip = v6[6] * 65536 + v6[7];
            v6 = null;
        }
        var domain = ip === null && v6 === null, local = false;
        if (v6 !== null) {
            var padded = [], leadingZero = true;
            for (var k = 0; k < 8; k++) {
                padded.push(v6[k].toString(16));
                if (k < 7 && v6[k] !== 0) leadingZero = false;
            }
            host = padded.join(":");
            if (leadingZero && v6[7] <= 1) return "DIRECT";
            local = (v6[0] & 65024) === 64512 || (v6[0] & 65472) === 65152;
        } else if (ip !== null) {
            host = [ip >>> 24, (ip >>> 16) & 255, (ip >>> 8) & 255, ip & 255].join(".");
        } else {
            if (claySuffix(host, "localhost")) return "DIRECT";
            local = host.indexOf(".") < 0 || claySuffix(host, "local");
        }
        if (ip !== null) {
            var first = ip >>> 24, second = (ip >>> 16) & 255;
            if (ip === 0 || first === 127) return "DIRECT";
            local = first === 10 || (first === 100 && second >= 64 && second <= 127) ||
                (first === 169 && second === 254) || (first === 172 && second >= 16 && second <= 31) ||
                (first === 192 && second === 168);
        }
        for (var i = 0; i < CLAYRules.length; i++) {
            var r = CLAYRules[i], name = r[0], needle = r[1];
            if (name === "IP-CIDR") {
                if (ip !== null && ((ip & r[2]) >>> 0) === needle) return r[3] ? "DIRECT" : CLAYProxy;
            } else if (name === "IP-CIDR6") {
                if (v6 !== null && clayIPv6Prefix(v6, needle, r[2])) return r[3] ? "DIRECT" : CLAYProxy;
            } else if ((name === "DOMAIN" && host === needle) ||
                       (domain && name === "DOMAIN-SUFFIX" && claySuffix(host, needle)) ||
                       (domain && name === "DOMAIN-KEYWORD" && host.indexOf(needle) >= 0)) {
                return r[2] ? "DIRECT" : CLAYProxy;
            }
        }
        if (CLAYBypassLocal && local) return "DIRECT";
        return CLAYDefault ? "DIRECT" : CLAYProxy;
    }
    """#
}

struct PACTarget {
    let host: String
    let ipv4: UInt32?
    let ipv6: [UInt16]?
    var isDomain: Bool { ipv4 == nil && ipv6 == nil }

    init?(_ input: String) {
        guard !input.isEmpty, !input.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else { return nil }
        var value = input.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
            guard value.contains(":") else { return nil }
        }
        if value.hasSuffix(".") { value.removeLast() }
        if value.contains(":") {
            let unscoped = value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            if unscoped.count == 2, unscoped[1].isEmpty || !unscoped[1].utf8.allSatisfy({ Self.isDomainCharacter($0) || $0 == 46 }) { return nil }
            guard let groups = Self.parseIPv6(String(unscoped[0])) else { return nil }
            if let address = Self.mappedIPv4(groups) {
                host = Self.ipv4Text(address)
                ipv4 = address
                ipv6 = nil
            } else {
                host = Self.ipv6Text(groups)
                ipv6 = groups
                ipv4 = nil
            }
        } else if let address = Self.parseIPv4(value) {
            host = Self.ipv4Text(address)
            ipv4 = address
            ipv6 = nil
        } else {
            guard value.rangeOfCharacter(from: CharacterSet(charactersIn: "%\\/:?#@[]")) == nil,
                  let ascii = URL(string: "http://\(value)/")?.host?.lowercased() else { return nil }
            let domain = ascii.hasSuffix(".") && !value.hasSuffix(".") ? String(ascii.dropLast()) : ascii
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            guard domain.utf8.count <= 253,
                  labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.utf8.allSatisfy(Self.isDomainCharacter) && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
            // IDNA folds some Unicode labels to numeric hosts (for example
            // full-width digits). Apply the same IP handling after that fold.
            ipv4 = domain == value ? nil : Self.parseIPv4(domain)
            host = ipv4.map(Self.ipv4Text) ?? domain
            ipv6 = nil
        }
    }

    fileprivate static func isDomainCharacter(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95 }

    // Parse IPv6 text without platform networking APIs. Keep normalization in
    // sync with clayIPv6, including IPv4-mapped addresses and strict octets.
    static func parseIPv6(_ input: String) -> [UInt16]? {
        guard !input.isEmpty, input.utf8.count <= 45 else { return nil }
        var value = input
        if value.contains(".") {
            guard let lastColon = value.lastIndex(of: ":"),
                  let ipv4 = parseIPv4(String(value[value.index(after: lastColon)...]), strict: true) else { return nil }
            value = String(value[...lastColon]) + String(ipv4 >> 16, radix: 16) + ":" + String(ipv4 & 0xffff, radix: 16)
        }
        func groups(_ slice: String) -> [UInt16]? {
            if slice.isEmpty { return [] }
            var result: [UInt16] = []
            for group in slice.split(separator: ":", omittingEmptySubsequences: false) {
                guard (1...4).contains(group.utf8.count),
                      group.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      let number = UInt16(group, radix: 16) else { return nil }
                result.append(number)
            }
            return result
        }
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2, let left = groups(halves[0]) else { return nil }
        if halves.count == 1 { return left.count == 8 ? left : nil }
        guard let right = groups(halves[1]), left.count + right.count < 8 else { return nil }
        return left + Array(repeating: 0, count: 8 - left.count - right.count) + right
    }

    static func parseIPv4(_ host: String, strict: Bool = false) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 4, !strict || parts.count == 4 else { return nil }
        var prefix: UInt64 = 0
        for (index, part) in parts.enumerated() {
            let number: UInt64?
            if part == "0" || (part.utf8.first.map { (49...57).contains($0) } == true && part.utf8.allSatisfy({ (48...57).contains($0) })) {
                number = UInt64(part, radix: 10)
            } else if !strict && part.hasPrefix("0x") && part.count > 2 && part.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                number = UInt64(part.dropFirst(2), radix: 16)
            } else if !strict && part.hasPrefix("0") && part.utf8.allSatisfy({ (48...55).contains($0) }) {
                number = UInt64(part, radix: 8)
            } else { return nil }
            guard let number else { return nil }
            if index == parts.count - 1 {
                let base = UInt64(1) << (8 * (5 - parts.count))
                return number < base ? UInt32(exactly: prefix * base + number) : nil
            }
            guard number <= 255 else { return nil }
            prefix = prefix * 256 + number
        }
        return nil
    }

    static func ipv4Text(_ ip: UInt32) -> String {
        [ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255].map(String.init).joined(separator: ".")
    }

    fileprivate static func ipv6Text(_ groups: [UInt16]) -> String {
        groups.map { String($0, radix: 16) }.joined(separator: ":")
    }

    fileprivate static func mappedIPv4(_ groups: [UInt16]) -> UInt32? {
        guard groups.prefix(5).allSatisfy({ $0 == 0 }), groups[5] == 65535 else { return nil }
        return UInt32(groups[6]) << 16 | UInt32(groups[7])
    }

    var isLoopback: Bool {
        if let ipv4 { return ipv4 == 0 || ipv4 >> 24 == 127 }
        if let ipv6 { return ipv6.prefix(7).allSatisfy({ $0 == 0 }) && ipv6[7] <= 1 }
        return host == "localhost" || host.hasSuffix(".localhost")
    }

    var isLocal: Bool {
        if let ipv4 {
            let first = ipv4 >> 24, second = (ipv4 >> 16) & 255
            return first == 10 || (first == 100 && (64...127).contains(second)) ||
                (first == 169 && second == 254) || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168)
        }
        if let ipv6 { return ipv6[0] & 0xfe00 == 0xfc00 || ipv6[0] & 0xffc0 == 0xfe80 }
        return !host.contains(".") || host.hasSuffix(".local")
    }
}

private struct PACIPv4CIDR {
    let network: UInt32
    let mask: UInt32
    let prefix: Int
    var text: String { "\(PACTarget.ipv4Text(network))/\(prefix)" }

    init?(_ text: String) {
        let fields = text.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2, let ip = PACTarget.parseIPv4(String(fields[0]), strict: true),
              !fields[1].isEmpty, fields[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let prefix = Int(fields[1]), (0...32).contains(prefix) else { return nil }
        self.prefix = prefix
        mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        network = ip & mask
    }
}

private struct PACIPv6CIDR {
    let network: [UInt16]
    let mask: [UInt16]
    let prefix: Int
    var text: String { "\(PACTarget.ipv6Text(network))/\(prefix)" }

    init?(_ text: String) {
        let fields = text.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2, let address = PACTarget.parseIPv6(fields[0].lowercased()),
              !fields[1].isEmpty, fields[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let prefix = Int(fields[1]), (0...128).contains(prefix) else { return nil }
        // A mapped-only range can never match: those destinations use IP-CIDR.
        guard prefix < 96 || PACTarget.mappedIPv4(address) == nil else { return nil }
        self.prefix = prefix
        mask = address.indices.map { index in
            let bits = min(16, max(0, prefix - index * 16))
            return bits == 0 ? 0 : UInt16.max << (16 - bits)
        }
        network = zip(address, mask).map { $0 & $1 }
    }

    func contains(_ address: [UInt16]) -> Bool {
        network.indices.allSatisfy { address[$0] & mask[$0] == network[$0] }
    }
}
