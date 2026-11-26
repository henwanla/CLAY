#if os(Windows)
import CLAYCore
import CWindowsRuntime
import Foundation

struct WindowsRunOptions {
    static let usage = """
    clay-portable mihomo-run FILE|--profile-stdin NODE_NUMBER MIHOMO_EXE SHA256 [--proxy-port PORT] [--control-port PORT]
      [--all-nodes] [--mode rule|global|direct] [--pac-rules FILE] [--interactive]
    """

    let source: String, executable: String, fingerprint: String, index: Int
    private(set) var proxyPort: UInt16 = 0, controlPort: UInt16 = 0
    private(set) var rules: String?
    private(set) var mode: CoreRoutingMode = .rule
    private(set) var allNodes = false, interactive = false

    init?(_ args: [String]) {
        guard args.count >= 5, !args[3].isEmpty, let index = Self.number(args[2]), index <= 100 else { return nil }
        (source, executable, fingerprint, self.index) = (args[1], args[3], args[4], Int(index))
        var seen = Set<String>(), i = 5
        while i < args.count {
            let key = args[i]
            guard seen.insert(key).inserted else { return nil }
            i += 1
            switch key {
            case "--all-nodes": allNodes = true; continue
            case "--interactive": interactive = true; continue
            default: break
            }
            guard i < args.count, !args[i].isEmpty, !args[i].hasPrefix("--") else { return nil }
            let value = args[i]
            i += 1
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
        }
    }

    fileprivate static func number(_ text: String) -> UInt16? {
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
        case Int32(CLAY_WIN_INPUT): self.init("Unable to read interactive commands from standard input.")
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
        var status: Int32
        do {
            let digits = Array("0123456789abcdef".utf8)
            let secret = String(decoding: random.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
            let node = profiles[options.index - 1]
            let nodes = options.allNodes ? profiles : [node]
            let config = try CoreConfig.make(nodes: nodes, active: node, proxyPort: Int(proxy), controlPort: Int(control),
                                             secret: secret, mode: options.mode, policy: policy)
            status = config.withUnsafeBytes { bytes in
                let data = bytes.bindMemory(to: UInt8.self)
                return options.interactive ? clay_win_start(session, data.baseAddress, data.count) :
                    clay_win_run(session, data.baseAddress, data.count)
            }
            if options.interactive, status == Int32(CLAY_WIN_OK) {
                let names = options.allNodes ? Dictionary(uniqueKeysWithValues: profiles.enumerated().map {
                    ($0.offset + 1, $0.element.localName)
                }) : [options.index: node.localName]
                status = interact(session: session, secret: secret, names: names)
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

    private static func interact(session: OpaquePointer, secret: String, names: [Int: String]) -> Int32 {
        var controller = WindowsSessionController(session: session, secret: secret)
        var input = [UInt8](repeating: 0, count: 512), line = [UInt8](), overlong = false
        while true {
            var count: UInt32 = 0
            let status = input.withUnsafeMutableBufferPointer {
                clay_win_read(session, $0.baseAddress, UInt32($0.count), &count)
            }
            if status == Int32(CLAY_WIN_EOF) { return Int32(CLAY_WIN_OK) }
            guard status == Int32(CLAY_WIN_OK) else { return status }
            for byte in input.prefix(Int(count)) {
                if byte != 10 {
                    if line.count < 128 { line.append(byte) } else { overlong = true }
                    continue
                }
                if line.last == 13 { line.removeLast() }
                let fields = overlong ? [] : String(decoding: line, as: UTF8.self)
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                line.removeAll(keepingCapacity: true)
                overlong = false
                let reply: String
                do {
                    switch fields.first {
                    case "quit" where fields.count == 1: return Int32(CLAY_WIN_OK)
                    case "help" where fields.count == 1:
                        reply = "commands: status | mode rule|global|direct | node N | quit"
                    case "status" where fields.count == 1:
                        try controller.finishRoutingChange()
                        let mode = try controller.mode(), active = try controller.node()
                        guard let number = names.first(where: { $0.value == active })?.key else { throw WindowsControlError.unconfirmed }
                        reply = "mode=\(mode.rawValue) node=\(number)"
                    case "mode" where fields.count == 2:
                        if let mode = CoreRoutingMode(rawValue: fields[1]) {
                            try controller.changeMode(mode)
                            reply = "mode=\(mode.rawValue)"
                        } else { reply = "error=invalid-command" }
                    case "node" where fields.count == 2:
                        if let number = WindowsRunOptions.number(fields[1]), let id = names[Int(number)] {
                            try controller.changeNode(id)
                            reply = "node=\(number)"
                        } else { reply = "error=unavailable-node" }
                    default: reply = "error=invalid-command"
                    }
                } catch WindowsControlError.sessionEnded(let result) { return result }
                catch { reply = "error=controller-unconfirmed" }
                let result = reply.withCString { clay_win_emit(session, $0) }
                if result != Int32(CLAY_WIN_OK) { return result }
            }
        }
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

private enum WindowsControlError: Error {
    case unconfirmed, sessionEnded(Int32)
}

private struct WindowsSessionController {
    let session: OpaquePointer, secret: String
    var drainPending = false

    func mode() throws -> CoreRoutingMode {
        guard let value = try request(Int32(CLAY_CTL_GET_MODE))["mode"] as? String,
              let mode = CoreRoutingMode(rawValue: value) else { throw WindowsControlError.unconfirmed }
        return mode
    }

    func node() throws -> String {
        guard let active = try request(Int32(CLAY_CTL_GET_NODE))["now"] as? String else { throw WindowsControlError.unconfirmed }
        return active
    }

    mutating func changeMode(_ mode: CoreRoutingMode) throws {
        if try self.mode() != mode {
            try change(Int32(CLAY_CTL_SET_MODE), body: "{\"mode\":\"\(mode.rawValue)\"}")
            guard try self.mode() == mode else { throw WindowsControlError.unconfirmed }
        }
        try finishRoutingChange()
    }

    mutating func changeNode(_ id: String) throws {
        if try node() != id {
            try change(Int32(CLAY_CTL_SET_NODE), body: "{\"name\":\"\(id)\"}")
            guard try node() == id else { throw WindowsControlError.unconfirmed }
        }
        try finishRoutingChange()
    }

    private mutating func change(_ operation: Int32, body: String) throws {
        drainPending = true
        _ = try request(operation, body: body)
    }

    mutating func finishRoutingChange() throws {
        guard drainPending else { return }
        _ = try request(Int32(CLAY_CTL_CLOSE_CONNECTIONS))
        drainPending = false
    }

    private func request(_ operation: Int32, body: String? = nil) throws -> [String: Any] {
        var response = [UInt8](repeating: 0, count: 64 * 1024), count: UInt32 = 0
        let status = secret.withCString { secret in
            response.withUnsafeMutableBufferPointer { buffer in
                if let body {
                    return body.withCString {
                        clay_win_control(session, operation, secret, $0, buffer.baseAddress, UInt32(buffer.count), &count)
                    }
                }
                return clay_win_control(session, operation, secret, nil, buffer.baseAddress, UInt32(buffer.count), &count)
            }
        }
        if status == Int32(CLAY_WIN_CONTROLLER) { throw WindowsControlError.unconfirmed }
        guard status == Int32(CLAY_WIN_OK) else { throw WindowsControlError.sessionEnded(status) }
        if body != nil || operation == Int32(CLAY_CTL_CLOSE_CONNECTIONS) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(response.prefix(Int(count)))) as? [String: Any] else {
            throw WindowsControlError.unconfirmed
        }
        return object
    }
}

#endif
