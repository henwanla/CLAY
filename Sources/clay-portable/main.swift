import CLAYCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import ucrt
#endif

private enum CommandError: Error {
    case usage, file, noNodes, invalidPolicy, missingSecret, controller
}

@main struct PortableCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] { print(usage); return }
        do { try run(arguments) }
        catch CommandError.usage { quit(usage, code: 64) }
        catch CommandError.file { quit("Unable to read a UTF-8 input file of up to 2 MiB.", code: 65) }
        catch CommandError.noNodes { quit("No supported nodes.", code: 65) }
        catch CommandError.invalidPolicy { quit("Invalid PAC rules, decision, or target.", code: 65) }
        catch PACError.invalidRuleLine(let line, _) { quit("Invalid PAC rule at line \(line).", code: 65) }
        catch CommandError.missingSecret { quit("Provide the configured controller secret on standard input.", code: 65) }
        catch { quit("The loopback Mihomo controller did not return a usable response.", code: 69) }
    }

    private static let usage = """
        clay-portable inspect FILE
        clay-portable pac-check RULES [HOST] [--default-direct] [--no-local-bypass]
        clay-portable pac-script RULES PORT [--default-direct] [--no-local-bypass]
        clay-portable mihomo-status PORT < SECRET_FILE  (Linux/macOS, requires /usr/bin/curl)
        """

    private static func run(_ arguments: [String]) throws {
        guard arguments.count >= 2 else { throw CommandError.usage }
        switch arguments[0] {
        case "inspect":
            guard arguments.count == 2 else { throw CommandError.usage }
            let report = ProfileImporter.read(try readText(arguments[1]))
            guard !report.profiles.isEmpty else { throw CommandError.noNodes }
            let groups = Dictionary(grouping: report.profiles) { "\($0.protocolName)/\($0.transport)/\($0.security)" }
            print("nodes=\(report.profiles.count)")
            for mode in groups.keys.sorted() { print("\(mode)=\(groups[mode]?.count ?? 0)") }
            for issue in report.issues.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                print("skipped.\(issue.rawValue)=\(report.issues[issue] ?? 0)")
            }
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
                let description: String
                switch match.reason {
                case .loopback: description = "loopback"
                case .local: description = "local"
                case .rule: description = "rule:\((match.ruleIndex ?? 0) + 1)"
                case .fallback: description = "default"
                }
                print("decision=\(match.decision.rawValue) source=\(description)")
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
        default: throw CommandError.usage
        }
    }

    private static func validPort(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
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
            return value.hasPrefix("\u{FEFF}") ? String(value.dropFirst()) : value
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
