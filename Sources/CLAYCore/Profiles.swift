import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

public enum ImportError: String, Error {
    case malformed, unsupportedProtocol, unsupportedTransport, unsupportedOption, invalidAccount, notProxyOutbound
}

private enum PasswordProtocol {
    case shadowsocks(cipher: String)
    case trojan(sni: String, alpn: [String]?)
}

public struct NodeProfile: Identifiable {
    public let id = UUID()
    public let name: String
    public let protocolName: String
    public let transport: String
    public let security: String
    public var localName: String { "node-" + id.uuidString.lowercased() }
    let options: [String: Any]

    public func hasSameConnection(as other: NodeProfile) -> Bool {
        NSDictionary(dictionary: options).isEqual(to: other.options)
    }

    private static func title(_ name: String, fallback: String) -> String {
        let title = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return title.isEmpty ? fallback : String(String.UnicodeScalarView(title)).prefix(140).description
    }

    init(name: String, kind: String, server: String, port: Int, account: String, network: String, security: String,
         cipher: String = "auto", alterID: Int = 0, host: String = "", path: String = "", sni: String = "",
         fingerprint: String = "", publicKey: String = "", shortID: String = "", flow: String = "",
         alpn: [String] = [], insecure: Bool = false, realityHybrid: Bool? = nil,
         udp: Bool = true, packetEncoding: String = "") throws {
        let network = network.lowercased(), security = security.lowercased()
        guard ["vmess", "vless"].contains(kind) else { throw ImportError.unsupportedProtocol }
        guard ["tcp", "raw", "ws", "grpc"].contains(network) else { throw ImportError.unsupportedTransport }
        guard ["none", "tls", "reality"].contains(security),
              (0...65_535).contains(alterID), (flow.isEmpty || kind == "vless" && flow == "xtls-rprx-vision" && ["raw", "tcp"].contains(network)),
              kind != "vmess" || ["auto", "none", "aes-128-gcm", "chacha20-poly1305", "zero"].contains(cipher),
              kind != "vmess" || security != "reality",
              ["", "packetaddr", "xudp"].contains(packetEncoding) else { throw ImportError.unsupportedOption }
        guard UUID(uuidString: account) != nil, (1...65535).contains(port), !server.isEmpty, server.utf8.count <= 253,
              server.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,58,95].contains($0) }) else { throw ImportError.invalidAccount }
        if security == "reality" {
            let key = publicKey.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard !sni.isEmpty, !fingerprint.isEmpty, !insecure, Base64.decode(key)?.count == 32,
                  shortID.count <= 16, shortID.count % 2 == 0, shortID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw ImportError.invalidAccount }
        }
        self.name = Self.title(name, fallback: kind.uppercased())
        self.protocolName = kind; self.transport = network == "raw" ? "tcp" : network; self.security = security
        var fields: [String: Any] = ["type": kind, "server": server, "port": port, "uuid": account.lowercased(), "network": self.transport, "udp": udp]
        if !packetEncoding.isEmpty { fields["packet-encoding"] = packetEncoding }
        if kind == "vmess" { fields["cipher"] = cipher; fields["alterId"] = alterID }
        if !flow.isEmpty { fields["flow"] = flow }
        if security != "none" { fields["tls"] = true; fields["skip-cert-verify"] = insecure }
        if !sni.isEmpty { fields["servername"] = sni }
        if !fingerprint.isEmpty { fields["client-fingerprint"] = fingerprint }
        if !alpn.isEmpty { fields["alpn"] = alpn }
        if security == "reality" {
            var reality: [String: Any] = ["public-key": publicKey, "short-id": shortID]
            if let realityHybrid { reality["support-x25519mlkem768"] = realityHybrid }
            fields["reality-opts"] = reality
        }
        if network == "ws" {
            guard path.isEmpty || path.hasPrefix("/") else { throw ImportError.unsupportedOption }
            var ws: [String: Any] = ["path": path.isEmpty ? "/" : path]
            if !host.isEmpty { ws["headers"] = ["Host": host] }
            fields["ws-opts"] = ws
        }
        if network == "grpc" && !path.isEmpty { fields["grpc-opts"] = ["grpc-service-name": path] }
        self.options = fields
    }

    fileprivate init(name: String, server: String, port: Int, password: String, udp: Bool, mode: PasswordProtocol) throws {
        guard Self.validPasswordNodeHost(server), (1...65535).contains(port), !password.isEmpty,
              !password.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw ImportError.invalidAccount }
        var fields: [String: Any] = ["server": server, "port": port, "password": password, "udp": udp]
        switch mode {
        case .shadowsocks(let cipher):
            guard ["aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305"].contains(cipher)
            else { throw ImportError.unsupportedOption }
            self.protocolName = "ss"
            self.security = "aead"
            fields["cipher"] = cipher
        case .trojan(let sni, let alpn):
            guard sni.isEmpty || Self.validPasswordNodeHost(sni) else { throw ImportError.unsupportedOption }
            if let alpn {
                guard alpn.allSatisfy({ (1...255).contains($0.utf8.count) && $0.utf8.allSatisfy { (33...126).contains($0) } }),
                      alpn.reduce(0, { $0 + $1.utf8.count + 1 }) <= 65_535 else { throw ImportError.unsupportedOption }
                fields["alpn"] = alpn
            }
            self.protocolName = "trojan"
            self.security = "tls"
            fields["network"] = "tcp"
            fields["skip-cert-verify"] = false
            if !sni.isEmpty { fields["sni"] = sni }
        }
        self.name = Self.title(name, fallback: protocolName == "ss" ? "Shadowsocks" : "Trojan")
        self.transport = "tcp"
        fields["type"] = protocolName
        self.options = fields
    }

    private static func validPasswordNodeHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, !host.utf8.contains(0) else { return false }
        if host.contains(":") {
            return PACTarget.parseIPv6(host.lowercased()) != nil
        }
        let name = host.hasSuffix(".") ? host.dropLast() : host[...]
        if name.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            return PACTarget.parseIPv4(host, strict: true) != nil
        }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" && label.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }
        }
    }
}

private enum Base64 {
    static func decode(_ text: String) -> Data? {
        var normalized = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }
}

public struct ImportResult {
    static let maxProfiles = 100
    public var profiles: [NodeProfile] = []
    public var issues: [ImportError: Int] = [:]
    mutating func add(_ result: () throws -> NodeProfile) {
        guard profiles.count < Self.maxProfiles else { issues[.unsupportedOption, default: 0] += 1; return }
        do { profiles.append(try result()) }
        catch { issues[(error as? ImportError) ?? .malformed, default: 0] += 1 }
    }
}

public enum ProfileImporter {
    public static let maxBytes = 2 * 1024 * 1024

    public static func read(_ text: String) -> ImportResult {
        var result = ImportResult()
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, text.utf8.count <= maxBytes else { result.issues[.malformed] = 1; return result }
        if raw.hasPrefix("{") || raw.hasPrefix("[") {
            guard let root = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) else {
                if let yaml = try? ClashYAML.read(raw, profile: fromClashProxy) { return yaml }
                result.issues[.malformed] = 1
                return result
            }
            let object = root as? [String: Any]
            if let proxies = object?["proxies"] {
                guard let nodes = proxies as? [Any] else { result.issues[.malformed] = 1; return result }
                for item in nodes { result.add { try fromClashProxy(item) } }
            } else {
                let outbounds = (object?["outbounds"] as? [Any]) ?? (root as? [Any]) ?? [root]
                for item in outbounds { result.add { try fromOutbound(item) } }
            }
        } else {
            if raw.contains(":"), !["vmess://", "vless://", "ss://", "trojan://"].contains(where: { raw.hasPrefix($0) }) {
                do {
                    if let yaml = try ClashYAML.read(raw, profile: fromClashProxy) { return yaml }
                } catch {
                    result.issues[.malformed] = 1
                    return result
                }
            }
            // Also accept pasted Base64 lists from offline subscription exports. No URL fetching.
            let lines: String
            if !raw.contains("://"), let data = Base64.decode(raw.filter { !$0.isWhitespace }), let decoded = String(data: data, encoding: .utf8) { lines = decoded }
            else { lines = raw }
            for l in lines.split(whereSeparator: { $0.isNewline }) {
                let link = l.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !link.isEmpty else { continue }
                result.add { try fromLink(link) }
            }
        }
        if result.profiles.isEmpty && result.issues.isEmpty { result.issues[.malformed] = 1 }
        return result
    }

    private static func int(_ value: Any?) -> Int? {
        if let s = value as? String { return Int(s) }
        if let n = value as? NSNumber, JSONNumberValue.isNumber(n) { return Int(n.stringValue) }
        return nil
    }

    private static func clashValue<T>(_ object: [String: Any], _ key: String, as type: T.Type) throws -> T? {
        guard let value = object[key] else { return nil }
        if type == Bool.self, let number = value as? NSNumber, JSONNumberValue.isNumber(number) { throw ImportError.malformed }
        guard let typed = value as? T else { throw ImportError.malformed }
        return typed
    }

    private static func fromClashProxy(_ item: Any) throws -> NodeProfile {
        guard let p = item as? [String: Any], let kind = p["type"] as? String else { throw ImportError.malformed }
        if kind == "ss" || kind == "trojan" { return try fromClashPasswordProxy(p, kind: kind) }
        guard ["vless", "vmess"].contains(kind) else { throw ImportError.unsupportedProtocol }
        guard let server = p["server"] as? String, let port = int(p["port"]), let account = p["uuid"] as? String else {
            throw ImportError.invalidAccount
        }
        let shared: Set<String> = ["type", "name", "server", "port", "uuid", "udp", "network", "tls", "servername", "client-fingerprint",
                                   "skip-cert-verify", "alpn", "ws-opts", "grpc-opts", "packet-encoding"]
        let extra: Set<String> = kind == "vless" ? ["flow", "encryption", "reality-opts"] : ["cipher", "alterId"]
        guard Set(p.keys).isSubset(of: shared.union(extra)),
              p["alterId"] == nil || int(p["alterId"]) != nil,
              ["", "none"].contains(try clashValue(p, "encryption", as: String.self) ?? "") else { throw ImportError.unsupportedOption }

        let network = try clashValue(p, "network", as: String.self) ?? "tcp"
        let tls = try clashValue(p, "tls", as: Bool.self) ?? false
        let ws = try clashValue(p, "ws-opts", as: [String: Any].self) ?? [:]
        let headers = try clashValue(ws, "headers", as: [String: String].self) ?? [:]
        let grpc = try clashValue(p, "grpc-opts", as: [String: Any].self) ?? [:]
        let reality = try clashValue(p, "reality-opts", as: [String: Any].self) ?? [:]
        let secure = p["reality-opts"] != nil ? "reality" : tls ? "tls" : "none"
        guard (network == "ws" || ws.isEmpty), (network == "grpc" || grpc.isEmpty), (secure != "reality" || tls),
              Set(ws.keys).isSubset(of: ["path", "headers"]), headers.count <= 1, headers.keys.allSatisfy({ $0.lowercased() == "host" }),
              Set(grpc.keys).isSubset(of: ["grpc-service-name"]),
              Set(reality.keys).isSubset(of: ["public-key", "short-id", "support-x25519mlkem768"]) else { throw ImportError.unsupportedOption }

        return try NodeProfile(name: clashValue(p, "name", as: String.self) ?? kind.uppercased(),
                               kind: kind, server: server, port: port, account: account, network: network, security: secure,
                               cipher: clashValue(p, "cipher", as: String.self) ?? "auto", alterID: int(p["alterId"]) ?? 0,
                               host: headers.values.first ?? "",
                               path: (network == "grpc" ? clashValue(grpc, "grpc-service-name", as: String.self) : clashValue(ws, "path", as: String.self)) ?? "",
                               sni: clashValue(p, "servername", as: String.self) ?? "",
                               fingerprint: clashValue(p, "client-fingerprint", as: String.self) ?? "",
                               publicKey: clashValue(reality, "public-key", as: String.self) ?? "",
                               shortID: clashValue(reality, "short-id", as: String.self) ?? "",
                               flow: clashValue(p, "flow", as: String.self) ?? "",
                               alpn: clashValue(p, "alpn", as: [String].self) ?? [],
                               insecure: clashValue(p, "skip-cert-verify", as: Bool.self) ?? false,
                               realityHybrid: clashValue(reality, "support-x25519mlkem768", as: Bool.self),
                               udp: clashValue(p, "udp", as: Bool.self) ?? false,
                               packetEncoding: clashValue(p, "packet-encoding", as: String.self) ?? "")
    }

    private static func fromClashPasswordProxy(_ p: [String: Any], kind: String) throws -> NodeProfile {
        let common: Set<String> = ["type", "name", "server", "port", "password", "udp"]
        let extra: Set<String> = kind == "ss" ? ["cipher"] : ["network", "tls", "sni", "alpn", "skip-cert-verify"]
        guard Set(p.keys).isSubset(of: common.union(extra)) else { throw ImportError.unsupportedOption }
        guard let server = p["server"] as? String, let port = int(p["port"]), let password = p["password"] as? String
        else { throw ImportError.invalidAccount }
        let mode: PasswordProtocol
        if kind == "ss" {
            guard let cipher = try clashValue(p, "cipher", as: String.self) else { throw ImportError.unsupportedOption }
            mode = .shadowsocks(cipher: cipher)
        } else {
            guard (try clashValue(p, "network", as: String.self) ?? "tcp") == "tcp" else { throw ImportError.unsupportedTransport }
            guard try clashValue(p, "tls", as: Bool.self) != false, try clashValue(p, "skip-cert-verify", as: Bool.self) != true
            else { throw ImportError.unsupportedOption }
            mode = .trojan(sni: try clashValue(p, "sni", as: String.self) ?? "", alpn: try clashValue(p, "alpn", as: [String].self))
        }
        return try NodeProfile(name: clashValue(p, "name", as: String.self) ?? "", server: server, port: port,
                               password: password, udp: clashValue(p, "udp", as: Bool.self) ?? false, mode: mode)
    }

    private static func fromPasswordLink(_ payload: String, kind: String) throws -> NodeProfile {
        // Parse the raw delimiters before percent decoding. URLComponents repairs malformed escapes.
        let tagged = payload.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let untagged = tagged.first else { throw ImportError.malformed }
        let queried = untagged.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = queried.first else { throw ImportError.malformed }
        let authority = address.split(separator: "@", omittingEmptySubsequences: false)
        guard authority.count == 2, !authority[0].isEmpty, !authority[1].isEmpty,
              authority[0].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                  || "-._~!$&'()*+,;=:%".utf8.contains($0) }) else { throw ImportError.malformed }
        let name: String
        if tagged.count == 2 {
            guard !tagged[1].contains("#"), let decoded = tagged[1].removingPercentEncoding else { throw ImportError.malformed }
            name = decoded
        } else { name = "" }

        let endpoint = authority[1].hasSuffix("/") ? authority[1].dropLast() : authority[1]
        guard let colon = endpoint.lastIndex(of: ":") else { throw ImportError.malformed }
        let host = endpoint[..<colon], portText = endpoint[endpoint.index(after: colon)...]
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }), let port = Int(portText)
        else { throw ImportError.invalidAccount }
        let server: String
        if host.hasPrefix("["), host.hasSuffix("]"), host.contains(":") {
            server = String(host.dropFirst().dropLast())
        } else {
            guard !host.contains(":") else { throw ImportError.malformed }
            server = String(host)
        }

        let password: String, mode: PasswordProtocol
        if kind == "ss" {
            guard queried.count == 1 else { throw ImportError.unsupportedOption }
            if authority[0].contains(":") {
                let parts = authority[0].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let cipher = parts[0].removingPercentEncoding, let decoded = parts[1].removingPercentEncoding
                else { throw ImportError.malformed }
                mode = .shadowsocks(cipher: cipher)
                password = decoded
            } else {
                guard let encoded = authority[0].removingPercentEncoding, let bytes = Base64.decode(encoded),
                      let userinfo = String(data: bytes, encoding: .utf8) else { throw ImportError.malformed }
                let parts = userinfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw ImportError.malformed }
                mode = .shadowsocks(cipher: String(parts[0]))
                password = String(parts[1])
            }
        } else {
            guard let decoded = authority[0].removingPercentEncoding else { throw ImportError.malformed }
            password = decoded
            var query: [String: String] = [:]
            if queried.count == 2 {
                for entry in queried[1].split(separator: "&", omittingEmptySubsequences: false) {
                    let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2, let key = pair[0].removingPercentEncoding, let value = pair[1].removingPercentEncoding,
                          query[key] == nil else { throw ImportError.malformed }
                    query[key] = value
                }
            }
            guard Set(query.keys).isSubset(of: ["type", "security", "sni", "alpn", "allowInsecure"]),
                  (query["security"] ?? "tls") == "tls", ["0", "false"].contains(query["allowInsecure"] ?? "0")
            else { throw ImportError.unsupportedOption }
            guard (query["type"] ?? "tcp") == "tcp" else { throw ImportError.unsupportedTransport }
            mode = .trojan(sni: query["sni"] ?? "", alpn: query["alpn"].map { $0.components(separatedBy: ",") })
        }
        return try NodeProfile(name: name, server: server, port: port, password: password, udp: true, mode: mode)
    }

    private static func fromLink(_ link: String) throws -> NodeProfile {
        if link.hasPrefix("ss://") { return try fromPasswordLink(String(link.dropFirst(5)), kind: "ss") }
        if link.hasPrefix("trojan://") { return try fromPasswordLink(String(link.dropFirst(9)), kind: "trojan") }
        if link.hasPrefix("vmess://") {
            guard let data = Base64.decode(String(link.dropFirst(8))), let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let server = p["add"] as? String, let account = p["id"] as? String, let port = int(p["port"]) else { throw ImportError.malformed }
            let network = p["net"] as? String ?? "tcp", kind = p["type"] as? String ?? "none"
            guard ["", "none"].contains(kind), p["aid"] == nil || int(p["aid"]) != nil else { throw ImportError.unsupportedOption }
            let tls = p["tls"] as? String ?? ""
            return try NodeProfile(name: p["ps"] as? String ?? "VMess", kind: "vmess", server: server, port: port, account: account, network: network, security: tls.isEmpty ? "none" : tls, cipher: p["scy"] as? String ?? "auto", alterID: int(p["aid"]) ?? 0, host: p["host"] as? String ?? "", path: p["path"] as? String ?? "", sni: p["sni"] as? String ?? "", fingerprint: p["fp"] as? String ?? "", alpn: (p["alpn"] as? String ?? "").split(separator: ",").map(String.init))
        }
        guard link.hasPrefix("vless://") else { throw ImportError.unsupportedProtocol }
        guard let uri = URLComponents(string: link), let account = uri.user, let host = uri.host, let port = uri.port, uri.password == nil, uri.path.isEmpty || uri.path == "/" else { throw ImportError.malformed }
        var q: [String: String] = [:]
        for query in uri.queryItems ?? [] {
            guard q[query.name] == nil, let v = query.value else { throw ImportError.malformed }
            q[query.name] = v
        }
        let known = Set(["type", "security", "encryption", "flow", "host", "path", "serviceName", "sni", "fp", "pbk", "sid", "alpn", "allowInsecure", "headerType", "mode", "spx", "support-x25519mlkem768"])
        guard Set(q.keys).isSubset(of: known), ["", "none"].contains(q["encryption"] ?? ""), ["", "none"].contains(q["headerType"] ?? ""), ["", "gun"].contains(q["mode"] ?? ""), ["", "0", "1"].contains(q["allowInsecure"] ?? ""), ["", "/"].contains(q["spx"] ?? "") else { throw ImportError.unsupportedOption }
        let hybrid = q["support-x25519mlkem768"]
        if let hybrid, !["true", "false"].contains(hybrid) || q["security"] != "reality" { throw ImportError.unsupportedOption }
        let network = q["type"] ?? "tcp"
        return try NodeProfile(name: uri.fragment ?? "VLESS", kind: "vless", server: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: port, account: account, network: network, security: q["security"] ?? "none", host: q["host"] ?? "", path: network == "grpc" ? q["serviceName"] ?? "" : q["path"] ?? "", sni: q["sni"] ?? "", fingerprint: q["fp"] ?? "", publicKey: q["pbk"] ?? "", shortID: q["sid"] ?? "", flow: q["flow"] ?? "", alpn: (q["alpn"] ?? "").split(separator: ",").map(String.init), insecure: q["allowInsecure"] == "1", realityHybrid: hybrid.map { $0 == "true" })
    }

    private static func fromOutbound(_ item: Any) throws -> NodeProfile {
        guard let p = item as? [String: Any], let kind = p["protocol"] as? String else { throw ImportError.malformed }
        if ["freedom", "blackhole", "dns"].contains(kind) { throw ImportError.notProxyOutbound }
        guard ["vmess", "vless"].contains(kind) else { throw ImportError.unsupportedProtocol }
        guard let settings = p["settings"] as? [String: Any], let next = settings["vnext"] as? [[String: Any]], next.count == 1,
              let users = next[0]["users"] as? [[String: Any]], users.count == 1,
              let server = next[0]["address"] as? String, let port = int(next[0]["port"]), let account = users[0]["id"] as? String else { throw ImportError.invalidAccount }
        let user = users[0], stream = p["streamSettings"] as? [String: Any] ?? [:]
        let sec = stream["security"] as? String ?? "none", network = stream["network"] as? String ?? "tcp"
        let ws = stream["wsSettings"] as? [String: Any] ?? [:], grpc = stream["grpcSettings"] as? [String: Any] ?? [:]
        let headers = ws["headers"] as? [String: Any] ?? [:], tcp = stream["tcpSettings"] as? [String: Any] ?? stream["rawSettings"] as? [String: Any] ?? [:]
        let tls = stream["tlsSettings"] as? [String: Any] ?? [:], reality = stream["realitySettings"] as? [String: Any] ?? [:]
        let tlsKeys = Set(["serverName", "fingerprint", "alpn", "allowInsecure"])
        guard p["proxySettings"] == nil, p["sendThrough"] == nil, (p["mux"] as? [String: Any])?["enabled"] as? Bool != true,
              Set(stream.keys).isSubset(of: ["network", "security", "tcpSettings", "rawSettings", "wsSettings", "grpcSettings", "tlsSettings", "realitySettings"]),
              Set(tls.keys).isSubset(of: tlsKeys), Set(ws.keys).isSubset(of: ["path", "headers"]), Set(headers.keys.map { $0.lowercased() }).isSubset(of: ["host"]),
              Set(grpc.keys).isSubset(of: ["serviceName", "multiMode"]), grpc["multiMode"] as? Bool != true,
              Set(tcp.keys).isSubset(of: ["header"]), ((tcp["header"] as? [String: Any])?["type"] as? String ?? "none") == "none",
              Set(reality.keys).isSubset(of: ["serverName", "fingerprint", "publicKey", "password", "shortId", "spiderX", "show"]),
              ["", "/"].contains(reality["spiderX"] as? String ?? ""), ["", "none"].contains(user["encryption"] as? String ?? "") else { throw ImportError.unsupportedOption }
        let security = sec == "reality" ? reality : tls
        return try NodeProfile(name: p["tag"] as? String ?? kind.uppercased(), kind: kind, server: server, port: port, account: account, network: network, security: sec, cipher: user["security"] as? String ?? "auto", alterID: int(user["alterId"]) ?? 0, host: headers.first(where: { $0.key.lowercased() == "host" })?.value as? String ?? "", path: (network == "grpc" ? grpc["serviceName"] : ws["path"]) as? String ?? "", sni: security["serverName"] as? String ?? "", fingerprint: security["fingerprint"] as? String ?? "", publicKey: (reality["publicKey"] ?? reality["password"]) as? String ?? "", shortID: reality["shortId"] as? String ?? "", flow: user["flow"] as? String ?? "", alpn: tls["alpn"] as? [String] ?? [], insecure: tls["allowInsecure"] as? Bool ?? false)
    }
}

private enum JSONNumberValue {
    static func isNumber(_ number: NSNumber) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(number) != CFBooleanGetTypeID()
        #else
        // Foundation boxes JSON and Swift booleans as the same two singleton numbers.
        // Numeric equality and casting to Bool can also accept integer 0 and 1.
        return number !== NSNumber(value: true) && number !== NSNumber(value: false)
        #endif
    }
}
