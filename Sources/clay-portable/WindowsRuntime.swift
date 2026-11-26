#if os(Windows)
import CLAYCore
import CWindowsRuntime
import Foundation

struct WindowsRunOptions {
    static let usage = """
    clay-portable mihomo-run FILE NODE_NUMBER MIHOMO_EXE SHA256 [--proxy-port PORT] [--control-port PORT]
      [--mode rule|global|direct] [--pac-rules FILE]
    """

    let source: String, executable: String, fingerprint: String, index: Int
    private(set) var proxyPort: UInt16 = 0, controlPort: UInt16 = 0
    private(set) var rules: String?
    private(set) var mode: CoreRoutingMode = .rule

    init?(_ args: [String]) {
        guard args.count >= 5, !args[3].isEmpty, let index = Self.number(args[2]), index <= 100 else { return nil }
        (source, executable, fingerprint, self.index) = (args[1], args[3], args[4], Int(index))
        var seen = Set<String>(), i = 5
        while i + 1 < args.count {
            let key = args[i], value = args[i + 1]
            guard seen.insert(key).inserted, !value.isEmpty, !value.hasPrefix("--") else { return nil }
            switch key {
            case "--mode":
                guard let selected = CoreRoutingMode(rawValue: value) else { return nil }
                mode = selected
            case "--proxy-port", "--control-port":
                guard let port = Self.number(value) else { return nil }
                if key == "--proxy-port" { proxyPort = port } else { controlPort = port }
            case "--pac-rules": rules = value
            default: return nil
            }
            i += 2
        }
        guard i == args.count else { return nil }
    }

    private static func number(_ text: String) -> UInt16? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt16(text), value > 0 else { return nil }
        return value
    }
}

struct WindowsMihomoError: Error {
    let message: String, exitCode: Int32

    init(_ message: String, _ exitCode: Int32 = 69) {
        self.message = message
        self.exitCode = exitCode
    }

    init(status: Int32) {
        switch status {
        case Int32(CLAY_WIN_DIGEST): self.init("Mihomo verification failed. Confirm the expected SHA-256.", 65)
        case Int32(CLAY_WIN_FILES): self.init("Unable to prepare or remove the private Mihomo runtime files.")
        case Int32(CLAY_WIN_PORTS): self.init("The requested loopback ports are unavailable.")
        case Int32(CLAY_WIN_LAUNCH): self.init("Unable to start or contain the verified Windows Mihomo executable.")
        case Int32(CLAY_WIN_EXITED): self.init("Mihomo exited before this session finished.")
        case Int32(CLAY_WIN_LISTENERS): self.init("Mihomo did not establish or keep its own loopback listeners.")
        case Int32(CLAY_WIN_OUTPUT): self.init("Unable to write the Mihomo loopback addresses to standard output.")
        case Int32(CLAY_WIN_SIGNALS): self.init("Unable to install console termination handling.")
        default: self.init("The Windows Mihomo session failed.")
        }
    }
}

enum WindowsMihomoRuntime {
    static func run(profiles: [NodeProfile], options: WindowsRunOptions, policy: PACPolicy?) throws -> Int32 {
        guard options.index <= profiles.count else { throw WindowsMihomoError("The selected node number is not in the imported list.", 65) }
        guard let digest = decodeFingerprint(options.fingerprint) else {
            throw WindowsMihomoError("Provide an expected SHA-256 as 64 hexadecimal characters.", 65)
        }
        guard options.proxyPort == 0 || options.proxyPort != options.controlPort else {
            throw WindowsMihomoError(status: Int32(CLAY_WIN_PORTS))
        }
        let path = Array(options.executable.utf16) + [0]
        var proxy: UInt16 = 0, control: UInt16 = 0, random = [UInt8](repeating: 0, count: 32)
        var session: OpaquePointer?
        let preparation = path.withUnsafeBufferPointer { path in
            digest.withUnsafeBufferPointer { digest in
                random.withUnsafeMutableBufferPointer { random in
                    clay_win_prepare(path.baseAddress, digest.baseAddress, options.proxyPort, options.controlPort,
                                     &proxy, &control, random.baseAddress, &session)
                }
            }
        }
        if preparation == Int32(CLAY_WIN_INTERRUPTED) { return 130 }
        guard preparation == Int32(CLAY_WIN_OK), let session else { throw WindowsMihomoError(status: preparation) }
        let status: Int32
        do {
            let digits = Array("0123456789abcdef".utf8)
            let secret = String(decoding: random.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
            let node = profiles[options.index - 1]
            let config = try CoreConfig.make(nodes: [node], active: node, proxyPort: Int(proxy), controlPort: Int(control),
                                             secret: secret, mode: options.mode, policy: policy)
            status = config.withUnsafeBytes { bytes in
                clay_win_run(session, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
        } catch {
            _ = clay_win_stop(session)
            throw WindowsMihomoError(status: Int32(CLAY_WIN_FILES))
        }
        let cleaned = clay_win_stop(session)
        guard cleaned == Int32(CLAY_WIN_OK) else { throw WindowsMihomoError(status: cleaned) }
        if status == Int32(CLAY_WIN_INTERRUPTED) { return 130 }
        guard status == Int32(CLAY_WIN_OK) else { throw WindowsMihomoError(status: status) }
        return 0
    }

    private static func decodeFingerprint(_ string: String) -> [UInt8]? {
        let bytes = Array(string.utf8)
        guard bytes.count == 64 else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var result = [UInt8]()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            result.append(high << 4 | low)
        }
        return result
    }
}

#endif
