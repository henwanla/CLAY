import CLAYCore
import Darwin
import Foundation

@main struct Tool {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2, ["inspect", "verify-config", "smoke", "smoke-telemetry"].contains(args[0]) else {
            print("clayctl inspect INPUT | clayctl verify-config INPUT MIHOMO | clayctl smoke INPUT MIHOMO TARGET_URL [EXPECTED_BODY] | clayctl smoke-telemetry INPUT MIHOMO LOOPBACK_TARGET"); exit(64)
        }
        let input = URL(fileURLWithPath: args[1]); let imported: ImportResult
        do {
            let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= ProfileImporter.maxBytes else { throw ImportError.malformed }
            imported = ProfileImporter.read(try String(contentsOf: input, encoding: .utf8))
        } catch { print("INPUT_UNREADABLE"); exit(65) }
        print("Imported \(imported.profiles.count) node(s): " + imported.profiles.map { "\($0.protocolName)/\($0.transport)/\($0.security)" }.joined(separator: ", "))
        for (reason, count) in imported.issues.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { print("Skipped \(reason.rawValue): \(count)") }
        guard let first = imported.profiles.first else { exit(65) }
        if args[0] == "inspect" { return }
        if args[0] == "verify-config" {
            guard args.count == 3 else { exit(64) }
            do { try verifyConfig(imported.profiles, first: first, engine: URL(fileURLWithPath: args[2])); print("PASS Mihomo accepted the generated configuration in test-only mode") }
            catch { print("FAIL engine config check"); exit(1) }
            return
        }
        guard args.count == 4 || args.count == 5, let target = URL(string: args[3]), ["http", "https"].contains(target.scheme ?? ""), target.host != nil else { exit(64) }
        if args[0] == "smoke-telemetry" {
            guard args.count == 4, target.scheme == "http", target.host == "127.0.0.1", target.port != nil,
                  target.user == nil, target.password == nil else { exit(64) }
            do { try await verifyTelemetry(profiles: imported.profiles, first: first, engine: URL(fileURLWithPath: args[2]), target: target) }
            catch { print("FAIL \((error as? SessionError)?.rawValue ?? "telemetry-check")"); exit(1) }
            return
        }
        // No app credential, node address, response body or downloaded file is printed.
        do { try await verify(imported.profiles, first: first, engine: URL(fileURLWithPath: args[2]), target: target, expected: args.count == 5 ? args[4] : nil) }
        catch { print("FAIL \((error as? SessionError)?.rawValue ?? "verification")"); exit(1) }
    }

    @MainActor static func verifyTelemetry(profiles: [NodeProfile], first: NodeProfile, engine: URL, target: URL) async throws {
        let session = try await CoreSession.start(engine: engine, nodes: profiles, active: first)
        defer { session.stopAndWait() }
        let initial = try await session.telemetry()
        guard initial.connectionCount == 0, initial.connections.isEmpty,
              initial.uploadRate == nil, initial.downloadRate == nil else { throw SessionError.telemetryUnavailable }
        try await Task.sleep(for: .milliseconds(150))

        var requests: [Process] = []
        defer { for p in requests { if p.isRunning { p.terminate(); p.waitUntilExit() } } }
        func startRequest() throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-q", "--silent", "--fail", "--max-time", "7", "--noproxy", "", "--proxy", session.proxyAddress, target.absoluteString]
            p.environment = ["PATH": "/usr/bin:/bin"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); requests.append(p)
        }
        try startRequest()
        try startRequest()
        // Sample long enough to see the forwarded response, but before the
        // synthetic origin finishes its held-open response.
        let deadline = ContinuousClock.now + .seconds(4)
        var matched: [ProxyConnection] = []
        var sawPositiveRates = false
        while ContinuousClock.now < deadline {
            let sample = try await session.telemetry()
            matched = sample.connections.filter { $0.destinationIP == "127.0.0.1" && $0.destinationPort == target.port && $0.download > 0 && $0.upload > 0 }
            if sample.uploadTotal > initial.uploadTotal, sample.downloadTotal > initial.downloadTotal,
               (sample.uploadRate ?? 0) > 0, (sample.downloadRate ?? 0) > 0 { sawPositiveRates = true }
            if matched.count == 2, sawPositiveRates { break }
            try await Task.sleep(for: .milliseconds(120))
        }
        guard matched.count == 2, sawPositiveRates, matched.allSatisfy({ row in
            row.network == "tcp" && row.type == "HTTP" && row.chains.contains(first.localName) && row.start != nil && !row.rule.isEmpty
        }) else { throw SessionError.telemetryUnavailable }
        try await session.closeConnection(matched[0].id)
        let afterOne = try await session.telemetry()
        guard !afterOne.connections.contains(where: { $0.id == matched[0].id }),
              afterOne.connections.contains(where: { $0.id == matched[1].id }) else { throw SessionError.closeConnectionsFailed }
        try await session.closeAllConnections()
        let afterAll = try await session.telemetry()
        guard afterAll.connectionCount == 0, afterAll.downloadTotal >= initial.downloadTotal else { throw SessionError.closeConnectionsFailed }
        print("PASS live totals, measured rates, connection details, and individual/all connection close")
    }

    static func verifyConfig(_ profiles: [NodeProfile], first: NodeProfile, engine: URL) throws {
        let fs = FileManager.default
        let dir = fs.temporaryDirectory.appendingPathComponent("clay-config-check-\(UUID().uuidString)", isDirectory: true)
        try fs.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fs.removeItem(at: dir) }
        let path = dir.appendingPathComponent("clay.json")
        let config = try CoreConfig.make(nodes: profiles, active: first, proxyPort: 39001, controlPort: 39002, secret: UUID().uuidString)
        try config.write(to: path, options: .withoutOverwriting)
        try fs.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let p = Process()
        p.executableURL = engine; p.arguments = ["-t", "-d", dir.path, "-f", path.path]
        p.currentDirectoryURL = dir
        p.environment = ["HOME": dir.path, "PATH": "/usr/bin:/bin"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SessionError.setupFailed }
    }

    @MainActor static func verify(_ profiles: [NodeProfile], first: NodeProfile, engine: URL, target: URL, expected: String?) async throws {
        let session = try await CoreSession.start(engine: engine, nodes: profiles, active: first)
        defer { session.stopAndWait() }
        print("Authenticated controller and owned proxy listener ready")
        for node in profiles {
            try await session.switchTo(node)
            for (kind, proxy) in [("HTTP", session.proxyAddress), ("SOCKS", "socks5h://127.0.0.1:\(session.proxyPort)")] {
                do { try fetch(proxy: proxy, target: target, expected: expected) }
                catch { print("FAIL \(node.protocolName)/\(node.transport)/\(node.security): \(kind) forwarding"); throw error }
            }
            let latency: Int
            do { latency = try await session.delay(node, target: target) }
            catch { print("FAIL \(node.protocolName)/\(node.transport)/\(node.security): node delay API"); throw error }
            print("PASS \(node.protocolName)/\(node.transport)/\(node.security): HTTP and SOCKS forwarding, \(latency) ms")
        }
        session.stopAndWait()
        guard !session.isRunning, !FileManager.default.fileExists(atPath: session.directory.path) else { throw SessionError.setupFailed }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        probe.arguments = ["-nP", "-iTCP@127.0.0.1:\(session.proxyPort)", "-sTCP:LISTEN", "-t"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        try probe.run(); probe.waitUntilExit()
        guard probe.terminationStatus == 1 else { throw SessionError.setupFailed }
        print("PASS child stopped, proxy listener released, runtime directory removed")
    }

    static func fetch(proxy: String, target: URL, expected: String?) throws {
        let p = Process(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-q", "--silent", "--fail", "--max-time", "7", "--max-filesize", "65536", "--noproxy", "", "--proxy", proxy, target.absoluteString]
        p.environment = ["PATH":"/usr/bin:/bin"]
        p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        let body = stdout.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, expected.map({ body == Data($0.utf8) }) ?? true else { throw SessionError.probeFailed }
    }
}
