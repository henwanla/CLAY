import CFNetwork
import CLAYCore
import Darwin
import Foundation
import JavaScriptCore

extension CoreTests {
    func testPACPolicy() throws {
        let rules = try PACPolicy.importRules("\u{FEFF}# synthetic\r\n" + """
        DOMAIN,local.example.test,PROXY
        DOMAIN-SUFFIX,*.EXAMPLE.TEST.,DIRECT
        DOMAIN-KEYWORD,Mirror,DIRECT
        IP-CIDR,198.51.100.5/24,DIRECT,no-resolve
        IP-CIDR,10.0.0.0/8,PROXY
        DOMAIN,localhost,PROXY
        DOMAIN,2001:db8::a,DIRECT
        DOMAIN,例え.テスト,DIRECT
        """)
        try pacExpect(rules[1].exportLine == "DOMAIN-SUFFIX,example.test,DIRECT", "canonical DNS suffix")
        try pacExpect(rules[3].exportLine == "IP-CIDR,198.51.100.0/24,DIRECT", "canonical network base")
        let policy = PACPolicy(rules: rules, defaultDecision: .proxy, bypassLocal: true)
        let restored = try JSONDecoder().decode(PACPolicy.self, from: JSONEncoder().encode(policy))
        try pacExpect(restored == policy, "policy persistence preserves IDs, order, and settings")

        let cases: [(String, PACDecision, PACMatch.Reason, Int?)] = [
            ("https://LOCAL.EXAMPLE.TEST./page", .proxy, .rule, 0),
            ("example.test", .direct, .rule, 1),
            ("sub.example.test", .direct, .rule, 1),
            ("notexample.test", .proxy, .fallback, nil),
            ("example.test.other", .proxy, .fallback, nil),
            ("friendly-mirror.test", .direct, .rule, 2),
            ("198.51.100.255", .direct, .rule, 3),
            ("198.51.101.0", .proxy, .fallback, nil),
            ("198.51.100.5.test", .proxy, .fallback, nil),
            ("10.2.3.4", .proxy, .rule, 4),
            ("192.168.50.1", .direct, .local, nil),
            ("172.16.0.1", .direct, .local, nil),
            ("172.32.0.1", .proxy, .fallback, nil),
            ("100.123.4.5", .direct, .local, nil),
            ("printer.LOCAL.", .direct, .local, nil),
            ("intranet", .direct, .local, nil),
            ("localhost", .direct, .loopback, nil),
            ("dev.localhost.", .direct, .loopback, nil),
            ("127.19.20.21", .direct, .loopback, nil),
            ("127.1", .direct, .loopback, nil),
            ("0x7f000001", .direct, .loopback, nil),
            ("0177.0.0.1", .direct, .loopback, nil),
            ("[::1]", .direct, .loopback, nil),
            ("[::ffff:127.0.0.1]", .direct, .loopback, nil),
            ("[fc88::70]", .direct, .local, nil),
            ("[fe80::1%lo0]", .direct, .local, nil),
            ("https://[2001:0DB8::0A]/", .direct, .rule, 6),
            ("https://例え.テスト/", .direct, .rule, 7)
        ]
        let script = try policy.makeScript(proxyPort: 1070)
        let js = try pacScriptFunction(script)
        for (input, decision, reason, index) in cases {
            let match = try policy.evaluate(input)
            try pacExpect(match.decision == decision && match.reason == reason && match.ruleIndex == index, "routing trace for \(input)")
            let host = input.contains("://") ? URL(string: input)?.host ?? "" : input
            let result = js.call(withArguments: [input, host])?.toString()
            try pacExpect(result == (decision == .direct ? "DIRECT" : "PROXY 127.0.0.1:1070"), "PAC script disagrees for \(input): \(result ?? "<missing>")")
        }
        let all = try PACRule(kind: .ipCIDR, value: "0.0.0.0/0", decision: .proxy)
        let relaxed = PACPolicy(rules: [all], defaultDecision: .direct, bypassLocal: false)
        let relaxedJS = try pacScriptFunction(relaxed.makeScript(proxyPort: 65535))
        for (host, expected) in [("239.255.255.255", "PROXY 127.0.0.1:65535"), ("localhost", "DIRECT"), ("example.net", "DIRECT")] {
            try pacExpect(relaxedJS.call(withArguments: [host, host])?.toString() == expected, "zero-bit CIDR for \(host)")
            try pacExpect(try relaxed.evaluate(host).decision == (expected == "DIRECT" ? .direct : .proxy), "fallback preview for \(host)")
        }
        let noLocal = PACPolicy(rules: [], defaultDecision: .proxy, bypassLocal: false)
        try pacExpect(try noLocal.evaluate("intranet").decision == .proxy, "local bypass is optional")
        try pacExpect(try noLocal.evaluate("１２７。１").reason == .loopback, "IDNA numeric normalization keeps loopback direct")

        let invalid: [(PACRule.Kind, String)] = [
            (.domain, "https://target.test/path"), (.domain, "target.test.."), (.domain, "[target.test]"),
            (.domain, "target.test\"; throw 'injected'; //"), (.domain, "user@target.test"),
            (.domainSuffix, "127.0.0.1"), (.domainSuffix, "*target.test"),
            (.domainKeyword, "broken\nrule"), (.ipCIDR, "198.51.100.5/33"),
            (.ipCIDR, "198.51.100.256/8"), (.ipCIDR, "198.051.100.5/8")
        ]
        for (kind, value) in invalid {
            try pacExpect((try? PACRule(kind: kind, value: value, decision: .proxy)) == nil, "invalid rule accepted: \(value)")
        }
        try pacExpect((try? policy.makeScript(proxyPort: 0)) == nil, "invalid proxy port accepted")
        do {
            _ = try PACPolicy.importRules("DOMAIN,valid.test,DIRECT\n# comment\nGEOIP,XX,DIRECT")
            throw PACCheckFailure("batch imported an unsupported third line")
        } catch PACError.invalidRuleLine(3, _) { }
    }

    func testIPv6PACPolicy() throws {
        let rules = try PACPolicy.importRules("""
        IP-CIDR6,2001:DB8:1:2:8000::9/128,PROXY,no-resolve
        IP-CIDR6,2001:db8:1:2:8000::123/65,DIRECT
        IP-CIDR6,::/0,PROXY
        IP-CIDR,198.51.100.0/24,PROXY
        DOMAIN,::ffff:203.0.113.9,PROXY
        """)
        try pacExpect(rules[1].exportLine == "IP-CIDR6,2001:db8:1:2:8000:0:0:0/65,DIRECT", "canonical IPv6 network base")
        let exported = try PACPolicy.importRules(rules.map(\.exportLine).joined(separator: "\n"))
        try pacExpect(exported.map(\.exportLine) == rules.map(\.exportLine), "IPv6 export round trip retains matching order")
        let policy = PACPolicy(rules: rules, defaultDecision: .direct, bypassLocal: false)
        let restored = try JSONDecoder().decode(PACPolicy.self, from: JSONEncoder().encode(policy))
        try pacExpect(restored == policy, "IPv6 policy round trip")
        let js = try pacScriptFunction(policy.makeScript(proxyPort: 1070))
        for (host, decision, reason, index): (String, PACDecision, PACMatch.Reason, Int?) in [
            ("[2001:db8:1:2:8000::9]", .proxy, .rule, 0),
            ("[2001:DB8:1:2:8000::]", .direct, .rule, 1),
            ("2001:db8:1:2:ffff:ffff:ffff:ffff", .direct, .rule, 1),
            ("2001:db8:1:2:7fff:ffff:ffff:ffff", .proxy, .rule, 2),
            ("2001:db8:1:3:8000::", .proxy, .rule, 2),
            ("[::ffff:198.51.100.7]", .proxy, .rule, 3),
            ("::ffff:cb00:7109", .proxy, .rule, 4),
            ("::ffff:203.0.113.10", .direct, .fallback, nil),
            ("::ffff:127.0.0.1", .direct, .loopback, nil),
            ("[::1]", .direct, .loopback, nil),
            ("ipv6-origin.test", .direct, .fallback, nil)
        ] {
            let hit = try policy.evaluate(host)
            try pacExpect(hit.decision == decision && hit.reason == reason && hit.ruleIndex == index, "IPv6 preview for \(host)")
            let expected = decision == .proxy ? "PROXY 127.0.0.1:1070" : "DIRECT"
            try pacExpect(js.call(withArguments: ["", host])?.toString() == expected, "IPv6 script for \(host)")
        }
        for invalid in ["2001:db8::/129", "2001:db8::/-1", "2001:db8::/+8", "2001:db8::/", "2001::db8::1/64",
                        "fe80::1%en0/64", "::ffff:192.0.2.1/96", "::ffff:c000:200/120", "192.0.2.0/24"] {
            try pacExpect((try? PACRule(kind: .ipCIDR6, value: invalid, decision: .proxy)) == nil, "invalid IPv6 CIDR: \(invalid)")
        }
    }

    func testPACServer() async throws {
        let rules = try PACPolicy.importRules("DOMAIN-SUFFIX,example.test,DIRECT\nDOMAIN,例え.テスト,DIRECT\nIP-CIDR6,2001:db8:1::/48,DIRECT")
        let policy = PACPolicy(rules: rules, defaultDecision: .proxy, bypassLocal: true)
        let script = try policy.makeScript(proxyPort: 1070)
        let first = try await PACServer.start(script: script)
        defer { first.stop() }
        let second = try await PACServer.start(script: "function FindProxyForURL(url, host) { return 'DIRECT'; }")
        defer { second.stop() }
        try pacExpect(first.url.host == "127.0.0.1" && first.url.port != nil && first.url.pathExtension == "pac", "PAC URL was not scoped to loopback")
        try pacExpect(first.url.path != second.url.path && first.url.port != second.url.port, "listener path or port was reused")
        let path = first.url.path
        let get = try pacRequest(first.url, "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let parts = get.components(separatedBy: "\r\n\r\n")
        try pacExpect(parts.count == 2 && parts[1] == script, "HTTP body differs from the generated script")
        try pacExpect(parts[0].hasPrefix("HTTP/1.1 200 OK") && parts[0].contains("Content-Type: application/x-ns-proxy-autoconfig") && parts[0].contains("Cache-Control: no-store"), "HTTP PAC headers")
        try testNativePAC(parts[1])
        let head = try pacRequest(first.url, "HEAD \(path) HTTP/1.0\r\n\r\n")
        try pacExpect(head.hasPrefix("HTTP/1.1 200 OK") && head.hasSuffix("\r\n\r\n") && head.contains("Content-Length: \(script.utf8.count)"), "HEAD should not return the script body")
        try pacExpect(try pacRequest(first.url, "GET / HTTP/1.0\r\n\r\n").hasPrefix("HTTP/1.1 404"), "root path exposed")
        try pacExpect(try pacRequest(first.url, "GET \(path)?alternate HTTP/1.0\r\n\r\n").hasPrefix("HTTP/1.1 404"), "query path exposed")
        try pacExpect(try pacRequest(first.url, "POST \(path) HTTP/1.0\r\n\r\n").hasPrefix("HTTP/1.1 405"), "non-read method accepted")
        try pacExpect(try pacRequest(first.url, "GET \(path) HTTP/1.0\r\nToo-Big: \(String(repeating: "a", count: 8210))\r\n\r\n").hasPrefix("HTTP/1.1 431"), "oversized header accepted")
        first.stop()
        first.stop()
        let refused = (try? pacRequest(first.url, "GET \(path) HTTP/1.0\r\n\r\n")) == nil
        try pacExpect(refused, "stopped listener still responds")
        try pacExpect(try pacRequest(second.url, "GET \(second.url.path) HTTP/1.0\r\n\r\n").hasPrefix("HTTP/1.1 200"), "stopping one listener stopped the other")
    }

    private func testNativePAC(_ script: String) throws {
        // CFNetwork evaluates PAC in an OS service. It may not be available in
        // test sandboxes, so this check lives with the loopback fixture.
        // Evaluating these synthetic URLs does not open connections to them.
        for (address, expected) in [("https://sub.example.test/", kCFProxyTypeNone), ("http://proxy.test/", kCFProxyTypeHTTP),
                                    ("https://proxy.test/", kCFProxyTypeHTTPS), ("https://例え.テスト/", kCFProxyTypeNone),
                                    ("https://[2001:db8:1::42]/", kCFProxyTypeNone), ("http://[2001:db8:2::42]/", kCFProxyTypeHTTP)] {
            var error: Unmanaged<CFError>?
            guard let url = URL(string: address),
                  let choices = CFNetworkCopyProxiesForAutoConfigurationScript(script as CFString, url as CFURL, &error)?.takeRetainedValue() as? [[String: Any]],
                  let type = choices.first?[kCFProxyTypeKey as String] as? String else {
                throw PACCheckFailure("native PAC result unavailable for \(address): \(String(describing: error?.takeRetainedValue()))")
            }
            try pacExpect(choices.count == 1 && type == expected as String, "native PAC result for \(address): \(choices)")
            if expected != kCFProxyTypeNone {
                try pacExpect(choices[0][kCFProxyHostNameKey as String] as? String == "127.0.0.1" &&
                              choices[0][kCFProxyPortNumberKey as String] as? Int == 1070, "native proxy endpoint")
            }
        }
    }
}

private struct PACCheckFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func pacExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw PACCheckFailure(message) }
}

private func pacScriptFunction(_ script: String) throws -> JSValue {
    guard let context = JSContext() else { throw PACCheckFailure("JavaScript context unavailable") }
    context.evaluateScript(script)
    guard context.exception == nil, let function = context.objectForKeyedSubscript("FindProxyForURL"), !function.isUndefined else {
        throw PACCheckFailure("PAC script failed to load: \(String(describing: context.exception))")
    }
    return function
}

// The fixture uses a raw loopback socket so it cannot inherit or alter the
// developer's live system proxy settings.
private func pacRequest(_ url: URL, _ request: String) throws -> String {
    guard let port = url.port else { throw PACCheckFailure("missing PAC port") }
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw PACCheckFailure("unable to create fixture socket: \(errno)") }
    defer { close(fd) }
    var on: Int32 = 1
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var endpoint = sockaddr_in()
    endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    endpoint.sin_family = sa_family_t(AF_INET)
    endpoint.sin_port = UInt16(port).bigEndian
    endpoint.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
    let result = withUnsafePointer(to: &endpoint) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { throw PACCheckFailure("fixture connection failed: \(errno)") }
    try Data(request.utf8).withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var sent = 0
        while sent < bytes.count {
            let count = send(fd, base.advanced(by: sent), bytes.count - sent, 0)
            guard count > 0 else { throw PACCheckFailure("fixture request failed: \(errno)") }
            sent += count
        }
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if count == 0 || (count < 0 && errno == ECONNRESET && !data.isEmpty) { break }
        guard count > 0 else { throw PACCheckFailure("fixture response failed: \(errno)") }
        data.append(contentsOf: buffer.prefix(count))
    }
    return String(decoding: data, as: UTF8.self)
}
