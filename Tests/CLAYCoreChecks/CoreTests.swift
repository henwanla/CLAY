import Foundation
import CLAYCore
import Darwin

@main struct CoreTests {
    @MainActor static func main() async throws {
        let tests = Self()
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--packet-fixture" {
            FileHandle.standardOutput.write(try tests.packetProfileFixture())
            return
        }
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--packet-profile-stdin" {
            FileHandle.standardOutput.write(try tests.packetProfileFromFixtureInput())
            return
        }
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
        try tests.testPasswordShareLinks()
        try tests.testClashPasswordNodes()
        try tests.testTrojanCertificatePin()
        tests.testPasswordNodesRejectUnsupportedOrAmbiguousInput()
        try tests.testHysteria2Nodes()
        tests.testHysteria2RejectsUnsupportedOrAmbiguousInput()
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
    func testPasswordShareLinks() throws {
        let userinfo = Data("aes-128-gcm:p+:/z".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let base64 = "ss://\(userinfo)@[::1]:443#%E6%B5%8B%E8%AF%95"
        let clear = "ss://aes-128-gcm:p%2B%3A%2Fz@[::1]:443/"
        let trojan = "trojan://p%3Aass%40word+%252F@127.0.0.1:443?type=tcp&security=tls&sni=example.test&alpn=h2,http%2F1.1&allowInsecure=0#Trojan"
        let result = ProfileImporter.read(Data([base64, clear, trojan].joined(separator: "\n").utf8).base64EncodedString())
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.profiles.map(\.name), ["测试", "Shadowsocks", "Trojan"])
        XCTAssertEqual(result.profiles.map(\.protocolName), ["ss", "ss", "trojan"])
        XCTAssertEqual(result.profiles.map(\.security), ["aead", "aead", "tls"])
        XCTAssertTrue(result.profiles[0].hasSameConnection(as: result.profiles[1]))
        let shadow = try fields(result.profiles[0])
        XCTAssertEqual(shadow["server"] as? String, "::1")
        XCTAssertEqual(shadow["cipher"] as? String, "aes-128-gcm")
        XCTAssertEqual(shadow["password"] as? String, "p+:/z")
        let options = try fields(result.profiles[2])
        XCTAssertEqual(options["password"] as? String, "p:ass@word+%2F")
        XCTAssertEqual(options["network"] as? String, "tcp")
        XCTAssertEqual(options["sni"] as? String, "example.test")
        XCTAssertEqual(options["alpn"] as? [String], ["h2", "http/1.1"])
        XCTAssertEqual(options["skip-cert-verify"] as? Bool, false)
    }

    func testClashPasswordNodes() throws {
        let yaml = """
        proxies:
          - {name: SS, type: ss, server: localhost, port: 1080, cipher: chacha20-ietf-poly1305, password: 001230, udp: false}
          - {name: Trojan, type: trojan, server: '::1', port: 8443, password: '  Hi: there #1  ', sni: example.test, alpn: [h2, http/1.1], skip-cert-verify: false, udp: true}
          - {name: Existing, type: vless, server: 127.0.0.1, port: 443, uuid: \(uuid)}
        """
        let json = """
        {"proxies":[
          {"name":"SS","type":"ss","server":"localhost","port":1080,"cipher":"chacha20-ietf-poly1305","password":"001230","udp":false},
          {"name":"Trojan","type":"trojan","server":"::1","port":8443,"password":"  Hi: there #1  ","network":"tcp","tls":true,"sni":"example.test","alpn":["h2","http/1.1"],"skip-cert-verify":false,"udp":true},
          {"name":"Existing","type":"vless","server":"127.0.0.1","port":443,"uuid":"\(uuid)"}
        ]}
        """
        let a = ProfileImporter.read(yaml), b = ProfileImporter.read(json)
        XCTAssertTrue(a.issues.isEmpty && b.issues.isEmpty)
        XCTAssertEqual(a.profiles.map(\.name), ["SS", "Trojan", "Existing"])
        XCTAssertEqual(b.profiles.map(\.name), a.profiles.map(\.name))
        XCTAssertTrue(zip(a.profiles, b.profiles).allSatisfy { $0.hasSameConnection(as: $1) })
        let shadow = try fields(a.profiles[0]), trojan = try fields(a.profiles[1])
        XCTAssertEqual(shadow["password"] as? String, "001230")
        XCTAssertEqual(shadow["udp"] as? Bool, false)
        XCTAssertEqual(trojan["password"] as? String, "  Hi: there #1  ")
        XCTAssertEqual(trojan["udp"] as? Bool, true)
        XCTAssertEqual(trojan["skip-cert-verify"] as? Bool, false)
    }

    func testPasswordNodesRejectUnsupportedOrAmbiguousInput() {
        let invalid: [(String, ImportError)] = [
            ("ss://", .malformed),
            ("trojan://#tag", .malformed),
            ("ss://aes-128-gcm:pw@127.0.0.1:443/?plugin=v2ray-plugin", .unsupportedOption),
            ("ss://aes-256-cfb:pw@127.0.0.1:443", .unsupportedOption),
            ("ss://2022-blake3-aes-128-gcm:pw@127.0.0.1:443", .unsupportedOption),
            ("ss://aes-128-gcm:pw%XX@127.0.0.1:443", .malformed),
            ("ss://aes-128-gcm:pw@127.0.0.1:443/path", .invalidAccount),
            ("ss://aes-128-gcm:pw@[::::]:443", .invalidAccount),
            ("ss://aes-128-gcm:pw@::1:443", .malformed),
            ("ss://aes-128-gcm:pw@[127.0.0.1]:443", .invalidAccount),
            ("ss://aes-128-gcm:pw@127.0.0.1:65536", .invalidAccount),
            ("ss://aes-128-gcm:@127.0.0.1:443", .invalidAccount),
            ("trojan://pw%00@127.0.0.1:443", .invalidAccount),
            ("trojan://p@ss@127.0.0.1:443", .malformed),
            ("trojan://pw@127.0.0.1:443?security=none", .unsupportedOption),
            ("trojan://pw@127.0.0.1:443?allowInsecure=1", .unsupportedOption),
            ("trojan://pw@127.0.0.1:443?type=ws", .unsupportedTransport),
            ("trojan://pw@127.0.0.1:443?sni=x.example&s%6Ei=y.example", .malformed),
            ("trojan://pw@127.0.0.1:443?sni=bad/name", .unsupportedOption),
            ("trojan://pw@127.0.0.1:443?alpn=h2,,http/1.1", .unsupportedOption),
            ("trojan://pw@127.0.0.1:443?fp=chrome", .unsupportedOption),
        ]
        for (input, error) in invalid {
            let parsed = ProfileImporter.read(input)
            XCTAssertTrue(parsed.profiles.isEmpty, "accepted invalid synthetic link")
            XCTAssertEqual(parsed.issues, [error: 1])
        }

        let yaml = """
        proxies:
          - {type: ss, server: localhost, port: 1080, cipher: aes-128-gcm, password: pw, plugin: obfs}
          - {type: trojan, server: localhost, port: 443, password: pw, dialer-proxy: other}
          - {type: trojan, server: localhost, port: 443, password: pw, skip-cert-verify: true}
          - {type: trojan, server: localhost, port: 443, password: pw, tls: false}
          - {type: trojan, server: localhost, port: 443, password: pw, network: grpc}
          - {type: trojan, server: localhost, port: 443, password: pw, skip-cert-verify: 0}
        """
        let parsed = ProfileImporter.read(yaml)
        XCTAssertTrue(parsed.profiles.isEmpty)
        XCTAssertEqual(parsed.issues, [.unsupportedTransport: 1, .unsupportedOption: 4, .malformed: 1])
    }

    func testTrojanCertificatePin() throws {
        let decorated = Array(repeating: "AB", count: 32).joined(separator: ":")
        func parse(_ pin: String, insecure: Bool = false) -> ImportResult {
            ProfileImporter.read("{proxies: [{type: trojan, server: origin.test, port: 443, password: example, fingerprint: '\(pin)', skip-cert-verify: \(insecure)}]}")
        }
        let pinned = try fields(XCTUnwrap(parse(decorated).profiles.first))
        XCTAssertEqual(pinned["fingerprint"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(pinned["skip-cert-verify"] as? Bool, false)
        for invalid in ["chrome", "AB::CD", String(repeating: "g0", count: 32), ""] {
            XCTAssertEqual(parse(invalid).issues, [.unsupportedOption: 1])
        }
        XCTAssertEqual(parse(decorated, insecure: true).issues, [.unsupportedOption: 1])
    }

    func testHysteria2Nodes() throws {
        let link = "hysteria2://fixture%3Apass%40word+%252F@[::1]/?sni=origin.test&insecure=0&obfs=salamander&obfs-password=0%2B1+2#My%20node"
        let alias = "hy2://fixture%3Apass%40word+%252F@[::1]:443?sni=origin.test&obfs=salamander&obfs-password=0%2B1%202"
        let yaml = """
        proxies:
          - {name: YAML, type: hysteria2, server: '::1', port: 443, password: 'fixture:pass@word+%2F', sni: origin.test, obfs: salamander, obfs-password: '0+1 2', udp: true}
        """
        let json = """
        {"proxies":[{"name":"JSON","type":"hysteria2","server":"::1","port":443,"password":"fixture:pass@word+%2F","sni":"origin.test","obfs":"salamander","obfs-password":"0+1 2","skip-cert-verify":false}]}
        """
        let result = SubscriptionImporter.parse(Data([link, alias].joined(separator: "\n").utf8).base64EncodedString())
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.profiles.map(\.name), ["My node", "Hysteria2"])
        let node = try XCTUnwrap(result.profiles.first)
        XCTAssertEqual(node.protocolName, "hysteria2")
        XCTAssertEqual(node.transport, "quic")
        XCTAssertEqual(node.security, "tls")
        XCTAssertTrue(node.hasSameConnection(as: result.profiles[1]))
        for input in [yaml, json] {
            let parsed = SubscriptionImporter.parse(input)
            XCTAssertTrue(parsed.issues.isEmpty)
            XCTAssertTrue(node.hasSameConnection(as: try XCTUnwrap(parsed.profiles.first)))
        }
        let options = try fields(node)
        XCTAssertEqual(options["type"] as? String, "hysteria2")
        XCTAssertEqual(options["server"] as? String, "::1")
        XCTAssertEqual(options["port"] as? Int, 443)
        XCTAssertEqual(options["password"] as? String, "fixture:pass@word+%2F")
        XCTAssertEqual(options["obfs"] as? String, "salamander")
        XCTAssertEqual(options["obfs-password"] as? String, "0+1 2")
        XCTAssertEqual(options["sni"] as? String, "origin.test")
        XCTAssertEqual(options["skip-cert-verify"] as? Bool, false)
        XCTAssertTrue(options["udp"] == nil && options["network"] == nil)

        let defaultPort = try XCTUnwrap(ProfileImporter.read("hy2://fixture@origin.test").profiles.first)
        XCTAssertEqual(try fields(defaultPort)["port"] as? Int, 443)
        let gecko = try XCTUnwrap(ProfileImporter.read("hy2://fixture@origin.test:8443?obfs=gecko&obfs-password=fixture").profiles.first)
        XCTAssertEqual(try fields(gecko)["port"] as? Int, 8443)
        XCTAssertEqual(try fields(gecko)["obfs"] as? String, "gecko")

        let fingerprint = Array(repeating: "AB", count: 32).joined(separator: ":")
        let pinned = "{proxies: [{type: hysteria2, server: origin.test, port: 443, password: fixture, skip-cert-verify: true, fingerprint: '\(fingerprint)'}]}"
        let pinFields = try fields(XCTUnwrap(ProfileImporter.read(pinned).profiles.first))
        XCTAssertEqual(pinFields["fingerprint"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(pinFields["skip-cert-verify"] as? Bool, false)
    }

    func testHysteria2RejectsUnsupportedOrAmbiguousInput() {
        let base = "hy2://fixture@origin.test:443?"
        let invalid: [(String, ImportError)] = [
            (base + "insecure=1", .unsupportedOption),
            (base + "pinSHA256=" + String(repeating: "ab", count: 32), .unsupportedOption),
            (base + "ech=fixture", .unsupportedOption),
            (base + "sni=bad/name", .unsupportedOption),
            (base + "sni=a.test&s%6Ei=b.test", .malformed),
            (base + "obfs=salamander", .unsupportedOption),
            (base + "obfs-password=fixture", .unsupportedOption),
            (base + "obfs=gecko&obfs-password=%00", .unsupportedOption),
            (base + "obfs=other&obfs-password=fixture", .unsupportedOption),
            ("hy2://fixture@origin.test:443,5000-5100", .unsupportedOption),
            ("hy2://fixture@origin.test:65536", .invalidAccount),
            ("hy2://fixture@origin.test:", .invalidAccount),
            ("hy2://fixture@::1", .malformed),
            ("hy2://fixture@[:::]", .invalidAccount),
            ("hy2://fixture%ZZ@origin.test", .malformed),
        ]
        for (input, error) in invalid {
            let result = ProfileImporter.read(input)
            XCTAssertTrue(result.profiles.isEmpty)
            XCTAssertEqual(result.issues, [error: 1])
        }
        for unsupported in ["skip-cert-verify: true", "fingerprint: 'ab:abcd'", "certificate: '/tmp/unknown'", "udp: false", "ports: '443-444'", "realm-opts: {}"] {
            let result = ProfileImporter.read("{proxies: [{type: hysteria2, server: origin.test, port: 443, password: fixture, \(unsupported)}]}")
            XCTAssertTrue(result.profiles.isEmpty)
            XCTAssertEqual(result.issues, [.unsupportedOption: 1])
        }
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
          {"name":"Other type","type":"socks5","server":"127.0.0.1","port":443},
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
          - {name: other protocol, type: socks5, server: 127.0.0.1, port: 443}
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
        do {
            _ = try await load("cross-origin")
            XCTAssertTrue(false, "followed a cross-origin redirect")
        } catch let error as SubscriptionError {
            XCTAssertTrue(error == .insecureRedirect || error == .network)
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

extension CoreTests {
    // This executable is a test fixture. Never use a personal profile here.
    func packetProfileFromFixtureInput() throws -> Data {
        let limit = ProfileImporter.maxBytes
        var data = Data()
        while let bytes = try FileHandle.standardInput.read(upToCount: min(8192, limit + 1 - data.count)), !bytes.isEmpty {
            data.append(bytes)
            guard data.count <= limit else { throw ImportError.malformed }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.malformed }
        let imported = ProfileImporter.read(text)
        guard imported.issues.isEmpty, !imported.profiles.isEmpty else { throw ImportError.malformed }
        return try CoreConfig.makePacketProfile(nodes: imported.profiles)
    }

    func packetProfileFixture() throws -> Data {
        let input = """
        proxies:
          - {name: Demo VMess, type: vmess, server: 127.0.0.1, port: 443, uuid: \(uuid), network: ws, ws-opts: {path: /demo, headers: {Host: example.test}}, tls: true, servername: example.test}
          - {name: Demo VLESS, type: vless, server: 127.0.0.1, port: 443, uuid: \(uuid), network: grpc, grpc-opts: {grpc-service-name: demo}, tls: true, udp: true, packet-encoding: xudp}
          - {name: Demo Shadowsocks, type: ss, server: 127.0.0.1, port: 443, cipher: aes-128-gcm, password: example}
          - {name: Demo Trojan, type: trojan, server: 127.0.0.1, port: 443, password: example, sni: example.test, alpn: [h2]}
          - {name: Demo Hysteria2, type: hysteria2, server: 127.0.0.1, port: 443, password: example, sni: example.test, obfs: salamander, obfs-password: demo}
        """
        let nodes = ProfileImporter.read(input).profiles
        XCTAssertEqual(nodes.map(\.protocolName), ["vmess", "vless", "ss", "trojan", "hysteria2"])
        let policy = PACPolicy(rules: try PACPolicy.importRules("""
        DOMAIN,first.example.test,PROXY
        DOMAIN-SUFFIX,example.test,DIRECT
        DOMAIN-KEYWORD,fixture,DIRECT
        DOMAIN,192.0.2.1,PROXY
        DOMAIN,2001:db8::1,DIRECT
        IP-CIDR,198.51.100.0/24,PROXY,no-resolve
        """), defaultDecision: .proxy, bypassLocal: true)
        let data = try CoreConfig.makePacketProfile(nodes: nodes, policy: policy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["proxies", "rules"]))
        let proxies = try XCTUnwrap(object["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.compactMap { $0["name"] as? String }, nodes.map(\.localName))
        let rules = try XCTUnwrap(object["rules"] as? [String])
        XCTAssertEqual(Array(rules.dropFirst(4).prefix(6)), ["DOMAIN,first.example.test,CLAY", "DOMAIN-SUFFIX,example.test,DIRECT",
                       "DOMAIN-KEYWORD,fixture,DIRECT", "IP-CIDR,192.0.2.1/32,CLAY,no-resolve",
                       "IP-CIDR6,2001:db8:0:0:0:0:0:1/128,DIRECT,no-resolve", "IP-CIDR,198.51.100.0/24,CLAY,no-resolve"])
        XCTAssertEqual(rules.last, "MATCH,CLAY")
        return data
    }
}
