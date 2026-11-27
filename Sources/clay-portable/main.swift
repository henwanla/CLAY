import CLAYCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif os(Windows)
import CWindowsRuntime
import ucrt
#endif

private enum CommandError: Error {
    case usage, file, profilePipe, targetPipe, noNodes, invalidPolicy, missingSecret, controller
}

private struct PortableCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] { print(usage); return }
        do { try run(arguments) }
        catch CommandError.usage { quit(usage, code: 64) }
        catch CommandError.file { quit("Unable to read a UTF-8 input file of up to 2 MiB.", code: 65) }
        catch CommandError.profilePipe { quit("Unable to read a UTF-8 profile from the private input pipe.", code: 65) }
        catch CommandError.targetPipe { quit("Rule preview requires private input and output pipes.", code: 65) }
        catch CommandError.noNodes { quit("No supported nodes.", code: 65) }
        catch CommandError.invalidPolicy { quit("Invalid PAC rules, decision, or target.", code: 65) }
        catch PACError.invalidRuleLine(let line, _) { quit("Invalid PAC rule at line \(line).", code: 65) }
        catch CommandError.missingSecret { quit("Provide the configured controller secret on standard input.", code: 65) }
        catch {
            #if os(Linux)
            if let problem = error as? LinuxMihomoError { quit(problem.message, code: problem.exitCode) }
            #elseif os(Windows)
            if let problem = error as? WindowsMihomoError { quit(problem.message, code: problem.exitCode) }
            #endif
            quit("The loopback Mihomo controller did not return a usable response.", code: 69)
        }
    }

    private static var usage: String {
        let common = """
        clay-portable inspect FILE|--profile-stdin [--numbered]
        clay-portable pac-check RULES [HOST] [--default-direct] [--no-local-bypass]
        clay-portable pac-script RULES PORT [--default-direct] [--no-local-bypass]
        clay-portable mihomo-status PORT < SECRET_FILE  (Linux/macOS, requires /usr/bin/curl)
        """
        #if os(Linux)
        return common + "\n" + LinuxRunOptions.usage
        #elseif os(Windows)
        return common + "\n" + WindowsRunOptions.usage
        #else
        return common
        #endif
    }

    private static func run(_ arguments: [String]) throws {
        guard arguments.count >= 2 else { throw CommandError.usage }
        switch arguments[0] {
        case "inspect":
            let numbered = arguments.count == 3 && arguments[2] == "--numbered"
            guard arguments.count == 2 || numbered else { throw CommandError.usage }
            let report = ProfileImporter.read(try readProfile(arguments[1]))
            guard !report.profiles.isEmpty else { throw CommandError.noNodes }
            printInspection(report, numbered: numbered, includeLabels: false)
        #if os(macOS) || os(Linux) || os(Windows)
        case "desktop-node-list":
            guard arguments == ["desktop-node-list", "--profile-stdin"] else { throw CommandError.usage }
            // Desktop parents use anonymous pipes in both directions. Reject
            // a terminal or a redirect to disk before reading the profile.
            guard desktopPipes() else { throw CommandError.profilePipe }
            let report = ProfileImporter.read(try readProfile(arguments[1]))
            guard !report.profiles.isEmpty else { throw CommandError.noNodes }
            printInspection(report, numbered: true, includeLabels: true)
        case "desktop-rule-preview":
            // A URL can carry private data. Accept the target only over a pipe.
            guard arguments.count == 2 else { throw CommandError.usage }
            guard desktopPipes() else { throw CommandError.targetPipe }
            desktopRulePreview(arguments[1])
        #endif
        case "pac-check", "pac-script":
            let values = arguments.dropFirst(2)
            let value = values.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
            let flags = value == nil ? values : values.dropFirst()
            let options = Set(flags)
            guard options.count == flags.count, options.isSubset(of: ["--default-direct", "--no-local-bypass"]) else {
                throw CommandError.usage
            }
            let rules = try PACPolicy.importRules(readText(arguments[1]))
            let policy = PACPolicy(rules: rules, defaultDecision: options.contains("--default-direct") ? .direct : .proxy,
                                   bypassLocal: !options.contains("--no-local-bypass"))
            if arguments[0] == "pac-script" {
                guard let value, let port = validPort(value) else { throw CommandError.usage }
                print(try policy.makeScript(proxyPort: port))
            } else if let value {
                guard let match = try? policy.evaluate(value) else { throw CommandError.invalidPolicy }
                print(decisionLine(match))
            } else {
                print("valid_pac_rules=\(rules.count)")
            }
        case "mihomo-status":
            guard arguments.count == 2, let port = validPort(arguments[1]) else { throw CommandError.usage }
            #if os(macOS) || os(Linux)
            try inspectController(port: port)
            #else
            throw CommandError.controller
            #endif
        #if os(Linux)
        case "mihomo-run":
            guard let options = LinuxRunOptions(arguments) else { throw CommandError.usage }
            let profiles = ProfileImporter.read(try readProfile(options.source)).profiles
            let policy = try options.rules.map(portablePolicy)
            let status = try LinuxMihomoRuntime.run(profiles: profiles, options: options, policy: policy)
            if status != 0 { exit(status) }
        #elseif os(Windows)
        case "mihomo-run":
            guard let options = WindowsRunOptions(arguments) else { throw CommandError.usage }
            let profiles = ProfileImporter.read(try readProfile(options.source)).profiles
            let policy = try options.rules.map(portablePolicy)
            let status = try WindowsMihomoRuntime.run(profiles: profiles, options: options, policy: policy)
            if status != 0 { exit(status) }
        #endif
        default: throw CommandError.usage
        }
    }

    private static func portablePolicy(_ path: String) throws -> PACPolicy {
        let rules = try PACPolicy.importRules(readText(path))
        return PACPolicy(rules: rules, defaultDecision: .proxy, bypassLocal: true)
    }

    private static func decisionLine(_ match: PACMatch) -> String {
        let source: String
        switch match.reason {
        case .loopback: source = "loopback"
        case .local: source = "local"
        case .rule: source = "rule:\((match.ruleIndex ?? 0) + 1)"
        case .fallback: source = "default"
        }
        return "decision=\(match.decision.rawValue) source=\(source)"
    }

    #if os(macOS) || os(Linux) || os(Windows)
    private static func desktopRulePreview(_ path: String) {
        guard let bytes = try? read(.standardInput, maxBytes: 4096), let target = String(data: bytes, encoding: .utf8),
              target.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            print("error=target")
            return
        }
        let policy: PACPolicy
        do { policy = try portablePolicy(path) }
        catch PACError.invalidRuleLine(let line, _) {
            print("error=rule-line:\(line)")
            return
        } catch {
            print("error=rules")
            return
        }
        if target.trimmingCharacters(in: .whitespaces).isEmpty {
            print("valid_pac_rules=\(policy.rules.count)")
        } else if let match = try? policy.evaluate(target) {
            print(decisionLine(match))
        } else {
            print("error=target")
        }
    }
    #endif

    private static func printInspection(_ report: ImportResult, numbered: Bool, includeLabels: Bool) {
        func kind(_ profile: NodeProfile) -> String { "\(profile.protocolName)/\(profile.transport)/\(profile.security)" }
        print("nodes=\(report.profiles.count)")
        if numbered {
            // Match mihomo-run ordering. Labels are opt-in for local window use only.
            for (index, profile) in report.profiles.enumerated() {
                let label = includeLabels ? " " + desktopLabel(profile.name) : ""
                print("node=\(index + 1) \(kind(profile))\(label)")
            }
        } else {
            let groups = Dictionary(grouping: report.profiles, by: kind)
            for mode in groups.keys.sorted() { print("\(mode)=\(groups[mode]?.count ?? 0)") }
        }
        for issue in report.issues.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            print("skipped.\(issue.rawValue)=\(report.issues[issue] ?? 0)")
        }
    }

    private static func desktopLabel(_ name: String) -> String {
        var cleaned = ""
        for scalar in name.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !cleaned.isEmpty && cleaned.last != " " { cleaned.append(" ") }
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            }
            if cleaned.unicodeScalars.count >= 64 { break }
        }
        let label = cleaned.trimmingCharacters(in: .whitespaces)
        // Links pasted into a display label can carry proxy credentials.
        guard !label.isEmpty, !label.contains("://") else { return "-" }
        return Data(label.utf8).base64EncodedString()
    }

    #if os(macOS) || os(Linux) || os(Windows)
    private static func desktopPipes() -> Bool {
        #if os(Windows)
        clay_win_stdio_is_piped() == 1
        #else
        var input = stat(), output = stat()
        return fstat(STDIN_FILENO, &input) == 0 && fstat(STDOUT_FILENO, &output) == 0 &&
            input.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO) && output.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO)
        #endif
    }
    #endif

    private static func validPort(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }

    private static func readProfile(_ source: String) throws -> String {
        guard source == "--profile-stdin" else { return try readText(source) }
        // A four-byte big-endian length followed by exactly that many UTF-8
        // bytes. Do not consume control lines that follow the profile frame.
        do {
            #if os(Windows)
            guard _isatty(0) == 0 else { throw CommandError.profilePipe }
            #else
            guard isatty(STDIN_FILENO) == 0 else { throw CommandError.profilePipe }
            #endif
            let handle = FileHandle.standardInput
            let header = try readExactly(4, from: handle)
            let size = header.reduce(0) { ($0 << 8) | Int($1) }
            guard (1...ProfileImporter.maxBytes).contains(size),
                  let value = String(data: try readExactly(size, from: handle), encoding: .utf8) else {
                throw CommandError.profilePipe
            }
            return withoutBOM(value)
        } catch { throw CommandError.profilePipe }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let next = try handle.read(upToCount: min(65_536, count - data.count)), !next.isEmpty
            else { throw CommandError.profilePipe }
            data.append(next)
        }
        return data
    }

    private static func withoutBOM(_ value: String) -> String {
        value.hasPrefix("\u{FEFF}") ? String(value.dropFirst()) : value
    }

    private static func readText(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        do {
            let file = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard file.isRegularFile == true else { throw CommandError.file }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = try read(handle, maxBytes: ProfileImporter.maxBytes)
            guard let value = String(data: bytes, encoding: .utf8) else { throw CommandError.file }
            return withoutBOM(value)
        } catch { throw CommandError.file }
    }

    private static func read(_ handle: FileHandle, maxBytes: Int) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maxBytes - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maxBytes - data.count else { throw CommandError.file }
            data.append(chunk)
        }
        return data
    }

    private static func quit(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    #if os(macOS) || os(Linux)
    private static func inspectController(port: Int) throws {
        // Require redirected stdin to avoid echoing the secret at a terminal.
        guard isatty(STDIN_FILENO) == 0,
              let raw = try? read(.standardInput, maxBytes: 4098),
              let text = String(data: raw, encoding: .utf8) else { throw CommandError.missingSecret }
        let secret = text.hasSuffix("\r\n") ? String(text.dropLast()) : text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard (1...4096).contains(secret.utf8.count), secret.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw CommandError.missingSecret
        }
        let version: ControllerVersion = try controllerGET(port: port, path: "/version", secret: secret, maxBytes: 65_536)
        guard !version.version.isEmpty else { throw CommandError.controller }
        let counters: ControllerCounts = try controllerGET(port: port, path: "/connections", secret: secret, maxBytes: 4 * 1024 * 1024)
        guard counters.uploadTotal >= 0, counters.downloadTotal >= 0 else { throw CommandError.controller }
        print("mihomo=ready upload_bytes=\(counters.uploadTotal) download_bytes=\(counters.downloadTotal)")
    }

    private struct ControllerVersion: Decodable { let version: String }
    private struct ControllerCounts: Decodable { let uploadTotal: Int64; let downloadTotal: Int64 }

    private static func controllerGET<Result: Decodable>(port: Int, path: String, secret: String, maxBytes: Int) throws -> Result {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // Fixed origin and paths, no user proxy, local curl configuration, or
        // redirects. The credential goes through stdin, never argv or env.
        process.arguments = ["-q", "--silent", "--no-location", "--noproxy", "*", "--proto", "=http", "--connect-timeout", "2",
                             "--max-time", "5", "--max-filesize", String(maxBytes), "--write-out", "\n%{http_code}",
                             "--header", "@-", "--", "http://127.0.0.1:\(port)\(path)"]
        process.environment = [:]
        process.standardInput = input.fileHandleForReading
        process.standardOutput = output.fileHandleForWriting
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            defer {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
            }
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            try input.fileHandleForWriting.write(contentsOf: Data("Authorization: Bearer \(secret)\n".utf8))
            try input.fileHandleForWriting.close()
            let data = try read(output.fileHandleForReading, maxBytes: maxBytes + 4)
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.suffix(4) == Data("\n200".utf8) else { throw CommandError.controller }
            return try JSONDecoder().decode(Result.self, from: data.dropLast(4))
        } catch { throw CommandError.controller }
    }
    #endif
}

PortableCLI.main()
