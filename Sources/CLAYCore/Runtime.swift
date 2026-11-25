#if os(macOS)
import CryptoKit
import Darwin
import Foundation

public enum SessionError: String, Error {
    case engineMissing, noNode, portsUnavailable, setupFailed, launchFailed, exitedDuringStart, controlUnavailable, selectionFailed, probeFailed
    case telemetryUnavailable, closeConnectionsFailed, engineChanged, routingFailed
}

public enum CoreRoutingMode: String, CaseIterable, Identifiable, Sendable {
    case rule, global, direct
    public var id: Self { self }
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

public enum CoreConfig {
    public static func make(nodes: [NodeProfile], active: NodeProfile, proxyPort: Int, controlPort: Int, secret: String,
                            mode: CoreRoutingMode = .rule, policy: PACPolicy? = nil) throws -> Data {
        guard let chosen = nodes.first(where: { $0.id == active.id }) else { throw SessionError.noNode }
        guard (1...65535).contains(proxyPort), (1...65535).contains(controlPort), proxyPort != controlPort, !secret.isEmpty else { throw SessionError.setupFailed }
        let ordered = [chosen] + nodes.filter { $0.id != chosen.id }
        return try JSONSerialization.data(withJSONObject: [
            "mixed-port": proxyPort, "bind-address": "127.0.0.1", "allow-lan": false, "mode": mode.rawValue,
            "ipv6": false, "log-level": "silent", "external-controller": "127.0.0.1:\(controlPort)", "secret": secret,
            "geo-auto-update": false, "find-process-mode": "off", "profile": ["store-selected": false],
            "tun": ["enable": false],
            "proxies": ordered.map { node in var p = node.options; p["name"] = node.localName; return p },
            "proxy-groups": [
                ["name": "CLAY", "type": "select", "proxies": ordered.map(\.localName)],
                ["name": "GLOBAL", "type": "select", "proxies": ["CLAY"]]
            ],
            "rules": policy.map(rules(for:)) ?? ["MATCH,CLAY"]
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func rules(for policy: PACPolicy) -> [String] {
        func group(_ action: PACDecision) -> String { action == .proxy ? "CLAY" : "DIRECT" }
        var result = ["DOMAIN-SUFFIX,localhost,DIRECT", "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
                      "IP-CIDR,0.0.0.0/32,DIRECT,no-resolve", "IP-CIDR6,::/127,DIRECT,no-resolve"]
        for rule in policy.rules {
            let action = group(rule.decision)
            var ipv4 = in_addr(), ipv6 = in6_addr()
            if rule.kind == .domain, inet_pton(AF_INET, rule.value, &ipv4) == 1 {
                result.append("IP-CIDR,\(rule.value)/32,\(action),no-resolve")
            } else if rule.kind == .domain, inet_pton(AF_INET6, rule.value, &ipv6) == 1 {
                result.append("IP-CIDR6,\(rule.value)/128,\(action),no-resolve")
            } else {
                result.append("\(rule.kind.rawValue),\(rule.value),\(action)\(rule.kind == .ipCIDR ? ",no-resolve" : "")")
            }
        }
        if policy.bypassLocal {
            result += ["DOMAIN-SUFFIX,local,DIRECT", "DOMAIN-REGEX,^[^.]+$,DIRECT"]
            result += ["10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16"]
                .map { "IP-CIDR,\($0),DIRECT,no-resolve" }
            result += ["fc00::/7", "fe80::/10"].map { "IP-CIDR6,\($0),DIRECT,no-resolve" }
        }
        result.append("MATCH,\(group(policy.defaultDecision))")
        return result
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
                             mode: CoreRoutingMode = .rule, policy: PACPolicy? = nil) async throws -> CoreSession {
        guard engine.isFileURL, FileManager.default.isExecutableFile(atPath: engine.path) else { throw SessionError.engineMissing }
        let ports = try reservePorts()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clay-runtime-\(UUID().uuidString)", isDirectory: true)
        let secret = UUID().uuidString + UUID().uuidString
        let configURL = directory.appendingPathComponent("clay.json")
        let process = Process()
        do {
            defer { ports.0.release(); ports.1.release() }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
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
                                secret: secret, mode: mode, policy: policy).write(to: configURL, options: .withoutOverwriting)
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

    private func call(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = [], maxBytes: Int = 65_536) async throws -> Data {
        guard !Task.isCancelled, await ownsListener(controlPort), !Task.isCancelled else { throw SessionError.controlUnavailable }
        var parts = URLComponents(); parts.scheme = "http"; parts.host = "127.0.0.1"; parts.port = controlPort; parts.path = path
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw SessionError.controlUnavailable }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await client.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
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
        do { _ = try await call(path, method: "DELETE") }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw SessionError.closeConnectionsFailed
        }
    }

    public func switchTo(_ node: NodeProfile) async throws {
        do { _ = try await call("/proxies/CLAY", method: "PUT", body: JSONEncoder().encode(["name": node.localName])) }
        catch { throw SessionError.selectionFailed }
    }

    public func setRoutingMode(_ mode: CoreRoutingMode) async throws {
        do { _ = try await call("/configs", method: "PATCH", body: JSONEncoder().encode(["mode": mode.rawValue])) }
        catch { throw SessionError.routingFailed }
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
