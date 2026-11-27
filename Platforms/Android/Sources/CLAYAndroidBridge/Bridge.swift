import CLAYCore
import Foundation

/// Private config for the local Android session. Unlike preview(), this output
/// contains credentials and must go directly into a private runtime file.
@_cdecl("clay_android_config")
public func relayConfig(
    _ source: UnsafePointer<UInt8>?, _ sourceCount: Int32,
    _ request: UnsafePointer<UInt8>?, _ requestCount: Int32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int32
) -> Int32 {
    guard let source = decode(source, sourceCount, max: ProfileImporter.maxBytes),
          let request = decode(request, requestCount, max: 16_384), let output, capacity > 0,
          let options = (try? JSONSerialization.jsonObject(with: Data(request.utf8))) as? [String: Any],
          let index = options["node"] as? Int, let proxy = options["proxy"] as? Int,
          let controller = options["controller"] as? Int, let secret = options["secret"] as? String,
          let password = options["password"] as? String,
          [secret, password].allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }),
          let name = options["mode"] as? String, let mode = CoreRoutingMode(rawValue: name),
          let rules = options["rules"] as? String, let ruleOptions = options["ruleOptions"] as? Int,
          (0...3).contains(ruleOptions) else { return -1 }
    let profiles = ProfileImporter.read(source).profiles
    guard profiles.indices.contains(index), let policyRules = try? PACPolicy.importRules(rules) else { return -1 }
    let policy = PACPolicy(rules: policyRules, defaultDecision: ruleOptions & 1 == 0 ? .proxy : .direct,
                           bypassLocal: ruleOptions & 2 != 0)
    guard let base = try? CoreConfig.make(nodes: profiles, active: profiles[index], proxyPort: proxy,
                                          controlPort: controller, secret: secret, mode: mode, policy: policy),
          var config = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] else { return -1 }
    // 127.0.0.1 is shared by apps on the device. Require session credentials
    // even on loopback; the controller uses its own independent secret.
    config["authentication"] = ["clay:\(password)"]
    config["skip-auth-prefixes"] = [String]()
    if options["vpn"] as? Bool == true {
        // Android owns all routes. The supplied DNS address is a regular
        // tunnel destination and follows the selected engine mode/rules.
        config["ipv6"] = true
        config["tun"] = ["enable": true, "stack": "gvisor", "auto-route": false,
                         "auto-detect-interface": false, "file-descriptor": 100, "mtu": 1500,
                         "inet4-address": ["198.18.0.1/30"], "inet6-address": ["fdfe:dcba:9876::1/126"],
                         "dns-hijack": [String]()]
        if policyRules.contains(where: \.requiresHostname) {
            // Use the name for matching only; keep the original IP and port.
            config["sniffer"] = ["enable": true, "parse-pure-ip": true, "force-dns-mapping": false,
                                 "override-destination": false, "sniff": [
                                    "HTTP": ["ports": ["80", "8000", "8080", "8081", "8888"], "override-destination": false],
                                    "TLS": ["ports": ["443", "8443", "9443"], "override-destination": false]
                                 ]]
        }
    }
    let ids = profiles.map(\.localName)
    // Mihomo reads this as YAML. Preserve the Swift encoding rather than
    // re-serializing the nested object with Android's slash-escaping JSON writer.
    guard let engine = try? JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]),
          let data = try? JSONSerialization.data(withJSONObject: ["engineConfig": String(decoding: engine, as: UTF8.self), "nodeIDs": ids, "nodeLabels": profiles.map(pickerLabel)]),
          data.count <= capacity else { return -1 }
    data.copyBytes(to: output, count: data.count)
    return Int32(data.count)
}

// Operations 0 and 1 return redacted previews. Operation 2 is for the protected, in-app node picker.
@_cdecl("clay_android_preview")
public func preview(
    _ operation: Int32,
    _ source: UnsafePointer<UInt8>?, _ sourceCount: Int32,
    _ target: UnsafePointer<UInt8>?, _ targetCount: Int32,
    _ options: Int32,
    _ output: UnsafeMutablePointer<UInt8>?, _ outputCapacity: Int32
) -> Int32 {
    let result: [String: Any]
    guard let output, outputCapacity > 0 else { return -1 }
    if let source = decode(source, sourceCount, max: ProfileImporter.maxBytes) {
        switch operation {
        case 0:
            let report = ProfileImporter.read(source)
            // Names are user-provided and can themselves contain a password or URL.
            result = ["nodes": report.profiles.map {
                ["protocol": $0.protocolName, "transport": $0.transport, "security": $0.security]
            }, "issues": Dictionary(uniqueKeysWithValues: report.issues.map { ($0.key.rawValue, $0.value) })]
        case 1:
            if let target = decode(target, targetCount, max: 16_384) {
                result = evaluatePAC(source, target: target, options: options)
            } else {
                result = ["error": "invalidHost"]
            }
        case 2: result = ["nodeLabels": ProfileImporter.read(source).profiles.map(pickerLabel)]
        default: result = ["error": "previewFailed"]
        }
    } else {
        result = ["error": "inputTooLarge"]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
          data.count <= outputCapacity else { return -1 }
    data.copyBytes(to: output, count: data.count)
    return Int32(data.count)
}

// Display labels have no structured credential fields. Strip controls and hide
// pasted URLs in names; keep the labels in the protected window and in memory.
private func pickerLabel(_ profile: NodeProfile) -> String {
    let safe = profile.name.unicodeScalars.lazy.filter {
        !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
    }.prefix(48)
    let title = String(String.UnicodeScalarView(safe)).trimmingCharacters(in: .whitespacesAndNewlines)
    let kind = profile.protocolName == "ss" ? "Shadowsocks" : profile.protocolName.uppercased()
    let detail = "\(kind) / \(profile.transport.uppercased())"
    return title.isEmpty || profile.name.contains("://") ? detail : "\(title) · \(detail)"
}

private func decode(_ bytes: UnsafePointer<UInt8>?, _ count: Int32, max: Int) -> String? {
    guard count >= 0, count <= max else { return nil }
    if count == 0 { return "" }
    guard let bytes else { return nil }
    return String(bytes: UnsafeBufferPointer(start: bytes, count: Int(count)), encoding: .utf8)
}

private func evaluatePAC(_ source: String, target: String, options: Int32) -> [String: Any] {
    do {
        let rules = try PACPolicy.importRules(source)
        let policy = PACPolicy(rules: rules, defaultDecision: options & 1 == 0 ? .proxy : .direct,
                               bypassLocal: options & 2 != 0)
        let match = try policy.evaluate(target)
        let reason: String
        switch match.reason {
        case .loopback: reason = "loopback"
        case .local: reason = "local"
        case .rule: reason = "rule"
        case .fallback: reason = "fallback"
        }
        var result: [String: Any] = ["decision": match.decision.rawValue, "reason": reason, "rules": rules.count]
        if let rule = match.ruleIndex { result["rule"] = rule + 1 }
        return result
    } catch PACError.invalidRuleLine(let line, _) {
        return ["error": "invalidRule", "line": line]
    } catch PACError.invalidHost {
        return ["error": "invalidHost"]
    } catch {
        return ["error": "previewFailed"]
    }
}
