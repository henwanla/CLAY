import Foundation
import CLAYCore
import Darwin

@main struct CoreTests {
    @MainActor static func main() async throws {
        let tests = Self()
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--subscription-fixture" {
            try await tests.testSubscriptionFixture(CommandLine.arguments[2])
            print("CLAY subscription download and refresh checks passed")
            return
        }
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--pac-fixture" {
            try await tests.testPACServer()
            print("CLAY loopback PAC fixture passed")
            return
        }
        try tests.testPACPolicy()
        try tests.testSystemPACRecovery()
        try tests.testImportVmessWs()
        try tests.testVlessRejectsSilentDowngradeOfUnsupportedOptions()
        try tests.testVlessRealityMappingRequiresExplicitKeyAndSNI()
        try tests.testFullConfigurationImportsOutboundButNotSystemInputs()
        tests.testOfflineSubscriptionTextNeverFetchesURLs()
        try tests.testDistinctEngineNodeNames()
        try tests.testSubscriptionURLAndBOM()
        try tests.testClashJSONImportsOnlySelfContainedSupportedNodes()
        try tests.testClashYAMLBlockAndFlow()
        tests.testClashYAMLRejectsAmbiguousOrExcessiveInput()
        print("CLAY core checks passed")
    }
    private func fields(_ n: NodeProfile) throws -> [String: Any] {
        let data = try CoreConfig.make(nodes: [n], active: n, proxyPort: 1234, controlPort: 1235, secret: "test")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((root["proxies"] as? [[String: Any]])?.first)
    }
    let uuid = "4624a73a-98ce-43e7-8868-4deba224779c"
    func testImportVmessWs() throws {
        let raw = """
        {"ps":"local","add":"localhost","port":"8080","id":"\(uuid)","net":"ws","tls":"tls","path":"/ws","host":"example.test","sni":"example.test","aid":"0"}
        """
        let r = ProfileImporter.read("vmess://" + Data(raw.utf8).base64EncodedString())
        let n = try XCTUnwrap(r.profiles.first)
        let options = try fields(n)
        XCTAssertTrue(r.issues.isEmpty)
        XCTAssertEqual(n.protocolName, "vmess"); XCTAssertEqual(n.security,"tls")
        XCTAssertEqual(options["servername"] as? String, "example.test")
        XCTAssertEqual(options["skip-cert-verify"] as? Bool, false)
        XCTAssertEqual((options["ws-opts"] as? [String: Any])?["path"] as? String, "/ws")
    }
    func testVlessRejectsSilentDowngradeOfUnsupportedOptions() throws {
        let prefix = "vless://\(uuid)@[::1]:443?"
        let valid = ProfileImporter.read(prefix + "type=grpc&security=tls&serviceName=clay#%E6%B5%8B%E8%AF%95")
        let n = try XCTUnwrap(valid.profiles.first)
        let options = try fields(n)
        XCTAssertEqual(n.name, "测试"); XCTAssertEqual(n.transport, "grpc"); XCTAssertEqual(options["server"] as? String, "::1")
        for q in ["type=xhttp", "security=tls&security=none", "type=grpc&mode=multi", "encryption=something", "security=reality", "junk=override"] {
            XCTAssertTrue(ProfileImporter.read(prefix + q).profiles.isEmpty, q)
        }
    }
    func testVlessRealityMappingRequiresExplicitKeyAndSNI() throws {
        let encoded = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let r = ProfileImporter.read("vless://\(uuid)@server.test:443?type=tcp&security=reality&sni=example.test&fp=chrome&pbk=\(encoded)&sid=01ab&flow=xtls-rprx-vision&support-x25519mlkem768=true")
        let n = try XCTUnwrap(r.profiles.first)
        let options = try fields(n)
        XCTAssertEqual(options["flow"] as? String, "xtls-rprx-vision")
        XCTAssertEqual((options["reality-opts"] as? [String: Any])?["short-id"] as? String, "01ab")
        XCTAssertEqual((options["reality-opts"] as? [String: Any])?["support-x25519mlkem768"] as? Bool, true)
    }
    func testFullConfigurationImportsOutboundButNotSystemInputs() throws {
        let raw = """
        {"tun":{"enable":true},"inbounds":[{"listen":"0.0.0.0","port":1080}],"outbounds":[{"protocol":"freedom"},{"tag":"User-set name","protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":8080,"users":[{"id":"\(uuid)","encryption":"none"}]}]}}]}
        """
        let r = ProfileImporter.read(raw)
        let n = try XCTUnwrap(r.profiles.first)
        XCTAssertEqual(r.issues[.notProxyOutbound], 1)
        let config = try CoreConfig.make(nodes: r.profiles, active: n, proxyPort: 20300, controlPort: 20301, secret: "test")
        let c = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        XCTAssertEqual(c["mixed-port"] as? Int, 20300)
        XCTAssertEqual(c["bind-address"] as? String, "127.0.0.1")
        XCTAssertEqual(c["external-controller"] as? String, "127.0.0.1:20301")
        XCTAssertEqual(c["allow-lan"] as? Bool, false)
        XCTAssertEqual((c["tun"] as? [String: Bool])?["enable"], false)
        XCTAssertEqual(c["rules"] as? [String], ["MATCH,CLAY"])
        XCTAssertFalse(String(decoding: config, as: UTF8.self).contains("User-set name"))
    }
    func testDistinctEngineNodeNames() throws {
        let link = "vless://\(uuid)@127.0.0.1:1234?type=ws&path=%2Fclay#Same"
        let nodes = ProfileImporter.read(link + "\n" + link).profiles
        XCTAssertEqual(nodes.count, 2)
        XCTAssertTrue(nodes[0].localName != nodes[1].localName)
        let data = try CoreConfig.make(nodes: nodes, active: nodes[1], proxyPort: 1111, controlPort: 2222, secret: "synthetic")
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("/clay"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try XCTUnwrap(root["proxy-groups"] as? [[String: Any]])
        XCTAssertEqual(groups.first?["proxies"] as? [String], [nodes[1].localName, nodes[0].localName])
    }
    func testOfflineSubscriptionTextNeverFetchesURLs() {
        let list = "https://example.test/private\nvless://\(uuid)@127.0.0.1:1234"
        let r = ProfileImporter.read(Data(list.utf8).base64EncodedString())
        XCTAssertEqual(r.profiles.count, 1); XCTAssertEqual(r.issues[.unsupportedProtocol], 1)
    }

    func testSubscriptionURLAndBOM() throws {
        let url = try SubscriptionImporter.validatedURL("  https://example.test/sub?token=a%2Bb\n")
        XCTAssertEqual(url.absoluteString, "https://example.test/sub?token=a%2Bb")
        for address in ["file:///etc/hosts", "https://", "http://example.test/", "https://name:password@example.test/", "https://example.test/#secret", "https://example.test:99999/", "https://example.test/a b"] {
            do {
                _ = try SubscriptionImporter.validatedURL(address)
                XCTAssertTrue(false, "accepted an invalid address")
            } catch let error as SubscriptionError { XCTAssertEqual(error, .invalidURL) }
        }
        let link = "vless://\(uuid)@127.0.0.1:1234"
        let parsed = try XCTUnwrap(SubscriptionImporter.parse("\u{FEFF}" + Data(link.utf8).base64EncodedString()).profiles.first)
        let renamed = try XCTUnwrap(SubscriptionImporter.parse(link + "#new-name").profiles.first)
        let changed = try XCTUnwrap(SubscriptionImporter.parse("vless://\(uuid)@127.0.0.1:4321").profiles.first)
        XCTAssertTrue(parsed.hasSameConnection(as: renamed))
        XCTAssertFalse(parsed.hasSameConnection(as: changed))
    }

    func testClashJSONImportsOnlySelfContainedSupportedNodes() throws {
        let body = """
        {"allow-lan":true,"mixed-port":7000,"external-controller":"0.0.0.0:7001","proxy-providers":{"outside":{"type":"http","url":"https://example.test/ignored"}},"rules":["MATCH,DIRECT"],"proxies":[
          {"name":"Clash Node","type":"vless","server":"127.0.0.1","port":443,"uuid":"\(uuid)","network":"ws","tls":true,"udp":false,"servername":"example.test","ws-opts":{"path":"/clay","headers":{"Host":"example.test"}}},
          {"name":"Other type","type":"ss","server":"127.0.0.1","port":443},
          {"name":"Chained node","type":"vless","server":"127.0.0.1","port":443,"uuid":"\(uuid)","dialer-proxy":"outside"}
        ]}
        """
        let result = SubscriptionImporter.parse(body)
        XCTAssertEqual(result.profiles.map(\.name), ["Clash Node"])
        XCTAssertEqual(result.issues[.unsupportedProtocol], 1)
        XCTAssertEqual(result.issues[.unsupportedOption], 1)
        let node = try XCTUnwrap(result.profiles.first)
        let options = try fields(node)
        XCTAssertEqual(node.transport, "ws")
        XCTAssertEqual(node.security, "tls")
        XCTAssertEqual(options["udp"] as? Bool, false)
        XCTAssertEqual((options["ws-opts"] as? [String: Any])?["path"] as? String, "/clay")
        let generated = try CoreConfig.make(nodes: [node], active: node, proxyPort: 1070, controlPort: 1071, secret: "synthetic")
        let text = String(decoding: generated, as: UTF8.self)
        XCTAssertFalse(text.contains("proxy-providers"))
        XCTAssertFalse(text.contains("MATCH,DIRECT"))
        XCTAssertFalse(text.contains("0.0.0.0"))
    }

    func testClashYAMLBlockAndFlow() throws {
        let key = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let block = """
        ---
        defaults: &sample { type: vless, server: 127.0.0.1, port: 443, uuid: \(uuid) }
        mixed-port: 7000
        proxy-providers:
          ignored: { type: http, url: https://example.test/ignored }
        proxies:
          - name: 'Azure: 本机 #1'
            type: vmess
            server: 127.0.0.1
            port: 443
            uuid: \(uuid)
            alterId: 0
            cipher: auto
            udp: true
            tls: true
            network: ws
            ws-opts:
              path: /ws
              headers: { Host: example.test }
          - *sample
          - { <<: *sample, name: merged }
          - {name: !custom Tag, type: vless, server: 127.0.0.1, port: 443, uuid: \(uuid)}
          - {name: duplicate, type: vless, server: 127.0.0.1, port: 443, port: 1234, uuid: \(uuid)}
          - {name: other protocol, type: ss, server: 127.0.0.1, port: 443}
          - {name: Reality, type: vless, server: 127.0.0.1, port: 443, uuid: \(uuid), tls: true, servername: example.test, client-fingerprint: chrome, reality-opts: { public-key: \(key), short-id: 001230 }}
        rules:
          - MATCH,DIRECT
        ...
        """
        let result = SubscriptionImporter.parse(block)
        XCTAssertEqual(result.profiles.map(\.name), ["Azure: 本机 #1", "Reality"])
        XCTAssertEqual(result.issues[.unsupportedOption], 4)
        XCTAssertEqual(result.issues[.unsupportedProtocol], 1)
        let websocket = try XCTUnwrap(result.profiles.first)
        let reality = try XCTUnwrap(result.profiles.last)
        XCTAssertEqual(websocket.transport, "ws")
        XCTAssertEqual((try fields(websocket)["ws-opts"] as? [String: Any])?["path"] as? String, "/ws")
        XCTAssertEqual((try fields(reality)["reality-opts"] as? [String: Any])?["short-id"] as? String, "001230")
        let flow = "{proxies: [{name: 'Flow', type: vless, server: '::1', port: 8443, uuid: \(uuid), tls: false}]}"
        XCTAssertEqual(SubscriptionImporter.parse(flow).profiles.map(\.name), ["Flow"])
    }

    func testClashYAMLRejectsAmbiguousOrExcessiveInput() {
        let node = "{name: test, type: vless, server: 127.0.0.1, port: 443, uuid: \(uuid)}"
        for input in [
            "proxies: [\(node)]\nproxies: [\(node)]", // Duplicate section.
            "proxies: [\(node)]\n---\nproxies: [\(node)]", // Multiple documents.
            "proxies: [\(node)]\nrules: [bad syntax", // Corrupt trailing section.
            "proxies: [\(node)]\nignored: " + String(repeating: "[", count: 80) + "a" + String(repeating: "]", count: 80),
            "proxy-providers: {outside: {type: http, url: https://example.test/not-loaded}}", // No usable nodes.
            "proxies: [\(node)]\nignored: [" + String(repeating: "0,", count: 200_000) + "]", // Event limit.
        ] {
            let parsed = SubscriptionImporter.parse(input)
            XCTAssertTrue(parsed.profiles.isEmpty)
            XCTAssertEqual(parsed.issues[.malformed], 1)
        }
        let largeList = "proxies:\n" + String(repeating: "  - \(node)\n", count: 105)
        let capped = SubscriptionImporter.parse(largeList)
        XCTAssertEqual(capped.profiles.count, 100)
        XCTAssertEqual(capped.issues[.unsupportedOption], 5)
    }

    func testSubscriptionFixture(_ address: String) async throws {
        let base = try SubscriptionImporter.validatedURL(address)
        func load(_ route: String) async throws -> (content: String, imported: ImportResult) {
            let target = base.appendingPathComponent(route)
            return try await SubscriptionImporter.fetch(target)
        }
        for route in ["plain", "base64", "redirect"] {
            let received = try await load(route)
            XCTAssertEqual(received.imported.profiles.map(\.name), ["local"])
            XCTAssertTrue(received.imported.issues.isEmpty)
            XCTAssertEqual(SubscriptionImporter.parse(received.content).profiles.map(\.name), ["local"])
        }
        let yaml = try await load("clash-yaml")
        XCTAssertEqual(yaml.imported.profiles.map(\.name), ["yaml"])
        XCTAssertEqual(SubscriptionImporter.parse(yaml.content).profiles.map(\.name), ["yaml"])
        for (route, expected) in [("empty", SubscriptionError.noSupportedProfiles), ("missing", .httpStatus(404)),
                                  ("large", .tooLarge), ("stream-large", .tooLarge)] {
            do {
                _ = try await load(route)
                XCTAssertTrue(false, "expected failure for \(route)")
            } catch let error as SubscriptionError {
                XCTAssertTrue(error == expected, "\(route): expected \(expected), got \(error)")
                XCTAssertFalse(error.localizedDescription.contains(base.absoluteString))
            }
        }
        do {
            _ = try await load("bad-redirect")
            XCTAssertTrue(false, "followed a non-HTTP redirect")
        } catch let error as SubscriptionError {
            XCTAssertTrue(error == .insecureRedirect || error == .network)
            XCTAssertFalse(error.localizedDescription.contains("file://"))
        }
        let first = try await load("changing")
        let refreshed = try await load("changing")
        XCTAssertEqual(first.imported.profiles.map(\.name), ["local"])
        XCTAssertEqual(refreshed.imported.profiles.map(\.name), ["replaced"])
        do {
            _ = try await load("changing")
            XCTAssertTrue(false, "expected a failed refresh")
        } catch let error as SubscriptionError { XCTAssertEqual(error, .httpStatus(503)) }
        XCTAssertEqual(SubscriptionImporter.parse(refreshed.content).profiles.map(\.name), ["replaced"])
    }
}

private enum CheckFailure: Error { case missing(Int) }
private func XCTUnwrap<T>(_ value: T?, line: Int = #line) throws -> T {
    guard let value else { throw CheckFailure.missing(line) }; return value
}
private func XCTAssertTrue(_ value: Bool, _ label: String = "", line: Int = #line) {
    if !value { print("FAIL line \(line): \(label)"); exit(1) }
}
private func XCTAssertFalse(_ value: Bool, line: Int = #line) { XCTAssertTrue(!value, line: line) }
private func XCTAssertEqual<T: Equatable>(_ given: T, _ expected: T, line: Int = #line) {
    XCTAssertTrue(given == expected, "expected \(expected), got \(given)", line: line)
}
