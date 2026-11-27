#if os(macOS)
import CryptoKit
import Darwin
import Foundation

extension CoreAppRoute {
    /// Match the path the kernel reports to Mihomo. Foundation's URL resolver
    /// can retain /var aliases even though proc_pidpath reports /private/var.
    public static func canonicalPath(_ url: URL) -> String? {
        guard url.isFileURL, let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingUTF8: resolved)
    }
}

extension NodeProfile {
    /// Persist only inside the private subscription catalog. The digest is
    /// stable across imports and ignores the display label and session UUID.
    public var connectionDigest: String {
        guard let data = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum EngineIdentity {
    public static func fingerprint(_ executable: URL) throws -> String {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path),
              try executable.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SessionError.engineMissing
        }
        let file = try FileHandle(forReadingFrom: executable)
        defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct PortReservation {
    let fd: Int32
    let number: Int
    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SessionError.portsUnavailable }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, len) } }
        guard ok == 0 else { close(descriptor); throw SessionError.portsUnavailable }
        let found = withUnsafeMutablePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &len) } }
        guard found == 0 else { close(descriptor); throw SessionError.portsUnavailable }
        fd = descriptor; number = Int(UInt16(bigEndian: addr.sin_port))
    }
    func release() { close(fd) }
}

private final class ControllerRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The controller's token is only valid for the owned loopback endpoint.
        completionHandler(nil)
    }
}

/// Starts only a child process owned by CLAY. No system proxy, routes, or services are changed.
@MainActor public final class CoreSession {
    public let proxyPort: Int
    public let directory: URL
    private let controlPort: Int
    private let secret: String
    private let process: Process
    private let client: URLSession
    private var trafficMeter = TrafficMeter()
    private var telemetryRequestInFlight = false
    private var drainPending = false
    public var isRunning: Bool { process.isRunning }
    public var proxyAddress: String { "http://127.0.0.1:\(proxyPort)" }

    private init(process: Process, proxyPort: Int, controlPort: Int, secret: String, directory: URL) {
        self.process = process; self.proxyPort = proxyPort; self.controlPort = controlPort; self.secret = secret; self.directory = directory
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.urlCache = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        client = URLSession(configuration: config, delegate: ControllerRedirectPolicy(), delegateQueue: nil)
    }

    public static func start(engine: URL, nodes: [NodeProfile], active: NodeProfile, expectedFingerprint: String? = nil,
                             mode: CoreRoutingMode = .rule, policy: PACPolicy? = nil,
                             routing: CoreRoutingPlan = .init()) async throws -> CoreSession {
        guard engine.isFileURL, FileManager.default.isExecutableFile(atPath: engine.path) else { throw SessionError.engineMissing }
        let ports = try reservePorts()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clay-runtime-\(UUID().uuidString)", isDirectory: true)
        let secret = UUID().uuidString + UUID().uuidString
        let configURL = directory.appendingPathComponent("clay.json")
        let process = Process()
        do {
            defer { ports.0.release(); ports.1.release() }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            if routing.bypassMainland {
                try installCountryData(in: directory)
            }
            if let expectedFingerprint {
                let copy = directory.appendingPathComponent("mihomo")
                do {
                    let source = engine.resolvingSymlinksInPath()
                    guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw SessionError.engineChanged
                    }
                    try FileManager.default.copyItem(at: source, to: copy)
                    guard try EngineIdentity.fingerprint(copy) == expectedFingerprint else { throw SessionError.engineChanged }
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: copy.path)
                } catch { throw SessionError.engineChanged }
                process.executableURL = copy
            } else { process.executableURL = engine }
            try CoreConfig.make(nodes: nodes, active: active, proxyPort: ports.0.number, controlPort: ports.1.number,
                                secret: secret, mode: mode, policy: policy, routing: routing).write(to: configURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            process.arguments = ["-d", directory.path, "-f", configURL.path]
            process.currentDirectoryURL = directory
            process.environment = ["HOME": directory.path, "TMPDIR": directory.path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { _ in try? FileManager.default.removeItem(at: directory) }
        } catch let error as SessionError {
            try? FileManager.default.removeItem(at: directory); throw error
        } catch {
            try? FileManager.default.removeItem(at: directory); throw SessionError.setupFailed
        }
        do { try process.run() } catch { try? FileManager.default.removeItem(at: directory); throw SessionError.launchFailed }
        let s = CoreSession(process: process, proxyPort: ports.0.number, controlPort: ports.1.number, secret: secret, directory: directory)
        do {
            for _ in 0..<25 {
                try Task.checkCancellation()
                guard process.isRunning else { throw SessionError.exitedDuringStart }
                if let version = try? await s.call("/version"), let object = try? JSONSerialization.jsonObject(with: version) as? [String: Any],
                   object["version"] is String, await s.ownsListener(s.proxyPort) { return s }
                try await Task.sleep(for: .milliseconds(120))
            }
            throw SessionError.controlUnavailable
        } catch { s.stopAndWait(); throw error }
    }

    private static func reservePorts() throws -> (PortReservation, PortReservation) {
        let proxy = try PortReservation()
        do { return (proxy, try PortReservation()) } catch { proxy.release(); throw error }
    }

    private static func installCountryData(in directory: URL) throws {
        let relative = "GeoIP/cn.dat"
        let expected = "d217d3e3f8b1b5c3a981dc912ec786360a33bcdc397ac1187b8e3ab1b54803ce"
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent(relative)]
        #if SWIFT_PACKAGE
        // SwiftPM runs from a build directory; packaged installs use the first URL.
        if Bundle.main.bundleURL.pathExtension != "app" { candidates.append(Bundle.module.resourceURL?.appendingPathComponent(relative)) }
        #endif
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url), data.count == 236235,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else { continue }
            try data.write(to: directory.appendingPathComponent("GeoIP.dat"), options: .withoutOverwriting)
            return
        }
        throw SessionError.countryDataUnavailable
    }

    private func ownsListener(_ port: Int) async -> Bool {
        guard process.isRunning else { return false }
        let pid = process.processIdentifier
        return await Task.detached(priority: .utility) {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            check.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP@127.0.0.1:\(port)", "-sTCP:LISTEN", "-t"]
            check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
            do { try check.run(); check.waitUntilExit(); return check.terminationStatus == 0 } catch { return false }
        }.value && process.isRunning
    }

    public func stopAndWait() {
        client.invalidateAndCancel()
        if process.isRunning { process.terminate() }
        for _ in 0..<25 where process.isRunning { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func call(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = [], maxBytes: Int = 65_536,
                      expectedStatus: Int? = nil) async throws -> Data {
        guard !Task.isCancelled, await ownsListener(controlPort), !Task.isCancelled else { throw SessionError.controlUnavailable }
        var parts = URLComponents(); parts.scheme = "http"; parts.host = "127.0.0.1"; parts.port = controlPort; parts.path = path
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw SessionError.controlUnavailable }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await client.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (expectedStatus.map { http.statusCode == $0 } ?? (200..<300).contains(http.statusCode)),
              response.expectedContentLength <= Int64(maxBytes) else { throw SessionError.controlUnavailable }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < maxBytes else { throw SessionError.controlUnavailable }
            data.append(byte)
        }
        return data
    }

    public func telemetry() async throws -> ProxyTelemetry {
        guard !telemetryRequestInFlight else { throw SessionError.telemetryUnavailable }
        telemetryRequestInFlight = true
        defer { telemetryRequestInFlight = false }
        do {
            let data = try await call("/connections", maxBytes: 4 * 1024 * 1024)
            try Task.checkCancellation()
            guard isRunning else { throw SessionError.telemetryUnavailable }
            let snapshot = try JSONDecoder().decode(MihomoSnapshot.self, from: data)
            return trafficMeter.sample(snapshot, at: .now, date: .now)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SessionError.telemetryUnavailable
        }
    }

    public func closeConnection(_ id: UUID) async throws {
        try await closeConnections("/connections/\(id.uuidString.lowercased())")
    }

    public func closeAllConnections() async throws { try await closeConnections("/connections") }

    private func closeConnections(_ path: String) async throws {
        do { _ = try await call(path, method: "DELETE", expectedStatus: 204) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw SessionError.closeConnectionsFailed
        }
    }

    private func selectedNodeName(in selector: String = "CLAY") async throws -> String {
        struct Selection: Decodable { let now: String }
        return try JSONDecoder().decode(Selection.self, from: await call("/proxies/\(selector)")).now
    }

    private func currentMode() async throws -> CoreRoutingMode {
        struct Configuration: Decodable { let mode: String }
        let value = try JSONDecoder().decode(Configuration.self, from: await call("/configs")).mode.lowercased()
        guard let mode = CoreRoutingMode(rawValue: value) else { throw SessionError.routingFailed }
        return mode
    }

    public func confirmedRouting() async throws -> (mode: CoreRoutingMode, nodeName: String) {
        guard !drainPending else { throw SessionError.closeConnectionsFailed }
        return (try await currentMode(), try await selectedNodeName())
    }

    public func switchTo(_ node: NodeProfile, group: UUID? = nil) async throws {
        do {
            let selectors = ["CLAY"] + (group.map { [CoreRoutingPlan.name(of: $0)] } ?? [])
            for selector in selectors {
                if try await selectedNodeName(in: selector) != node.localName {
                    drainPending = true
                    _ = try await call("/proxies/\(selector)", method: "PUT", body: JSONEncoder().encode(["name": node.localName]))
                    guard try await selectedNodeName(in: selector) == node.localName else { throw SessionError.selectionFailed }
                }
            }
            try await finishRoutingChange()
        } catch { throw SessionError.selectionFailed }
    }

    public func setRoutingMode(_ mode: CoreRoutingMode) async throws {
        do {
            if try await currentMode() != mode {
                drainPending = true
                _ = try await call("/configs", method: "PATCH", body: JSONEncoder().encode(["mode": mode.rawValue]))
                guard try await currentMode() == mode else { throw SessionError.routingFailed }
            }
            try await finishRoutingChange()
        } catch { throw SessionError.routingFailed }
    }

    private func finishRoutingChange() async throws {
        guard drainPending else { return }
        try await closeAllConnections()
        drainPending = false
    }

    public func delay(_ node: NodeProfile, target: URL) async throws -> Int {
        guard ["http", "https"].contains(target.scheme ?? ""), target.host != nil else { throw SessionError.probeFailed }
        do {
            let data = try await call("/proxies/\(node.localName)/delay", query: [.init(name: "url", value: target.absoluteString), .init(name: "timeout", value: "5000")])
            guard let ms = try JSONDecoder().decode([String: Int].self, from: data)["delay"], ms >= 0 else { throw SessionError.probeFailed }
            return ms
        } catch { throw SessionError.probeFailed }
    }
}
#endif
