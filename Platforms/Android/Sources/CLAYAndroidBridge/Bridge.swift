import CLAYCore
import Foundation

// The JNI adapter owns the memory; only sanitized JSON may cross back into Java.
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
