import Darwin
@_spi(Checks) import CLAYCore
import Foundation

private struct CheckFailed: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class NoSystemPACBackend: SystemPACBackend {
    func withLocked<T>(interactive: Bool, _ body: (any SystemPACSession) throws -> T) throws -> T {
        throw CheckFailed("unexpected system PAC mutation")
    }
}

@main struct WorkspaceChecks {
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            try SubscriptionStorageChecks.run()
            if args.count == 2, args[1] == "--storage-only" { return }
            guard args.count == 4 else { throw CheckFailed("expected loopback origin, Mihomo, and temporary catalog directory") }
            let directory = URL(filePath: args[3], directoryHint: .isDirectory)
            let store = SubscriptionStore(directory: directory, keyStore: TestSubscriptionKeyStore())
            let recoveryDirectory = directory.appendingPathComponent("pac-recovery")
            let manager = SystemPACManager(backend: NoSystemPACBackend(), journalDirectory: recoveryDirectory)
            let suite = "CLAYWorkspaceChecks-\(UUID())"
            guard let preferences = UserDefaults(suiteName: suite) else { throw CheckFailed("could not isolate preferences") }
            defer { preferences.removePersistentDomain(forName: suite) }
            let model = Workspace(store: store, pac: PACControl(manager: manager, preferences: preferences), preferences: preferences)
            let engine = URL(filePath: args[2])
            try model.trustEngine(engine, persist: false)
            do {
                try await checkRefresh(model, store: store, origin: args[1], directory: directory)
                try await checkEnginePin(engine: engine, model: model)
                try await checkBackgroundHealth(model)
            } catch {
                await model.shutdown()
                throw error
            }
            await model.shutdown()
            print("PASS running listener stays available through refresh and failure; stop and offline reload use the last successful list")
            print("PASS background health monitor notices exit of the owned Mihomo and clears its listener without a window")
            print("PASS local PAC published with the live proxy port and was removed before the proxy listener")
            print("PASS rule, global, and direct mode changes affect real loopback requests without changing the listening address")
            print("PASS a mismatched executable fingerprint is rejected before launching the core")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }

    @MainActor private static func checkEnginePin(engine: URL, model: Workspace) async throws {
        guard let node = model.chosen else { throw CheckFailed("no fixture profile for the engine check") }
        let actual = try EngineIdentity.fingerprint(engine)
        let different = (actual.first == "0" ? "1" : "0") + actual.dropFirst()
        do {
            let unexpected = try await CoreSession.start(engine: engine, nodes: [node], active: node, expectedFingerprint: different)
            unexpected.stopAndWait()
            throw CheckFailed("started an executable with a mismatched fingerprint")
        } catch SessionError.engineChanged {
            // This is the expected failure before opening the control endpoint.
        }
    }

    @MainActor private static func checkRefresh(_ model: Workspace, store: SubscriptionStore, origin: String, directory: URL) async throws {
        let token = "synthetic-fixture-token"
        model.addSubscription(name: "Fixture", input: origin + "/changing?token=" + token)
        try await wait("initial download") { !model.fetchingSubscription }
        guard let source = model.selectedSubscription else { throw CheckFailed("known subscription was not selected") }
        try require(model.nodes.map(\.name) == ["local"], "initial nodes were not installed")
        try require(model.subscriptions.map(\.count) == [1], "subscription summary is missing its initial count")

        model.start()
        try await wait("Mihomo readiness") { model.running || !model.busy }
        guard let listener = model.proxyAddress, let port = URL(string: listener)?.port, let localPort = UInt16(exactly: port) else {
            throw CheckFailed("synthetic Mihomo did not start")
        }
        try require(canConnect(to: localPort), "owned proxy socket is not listening")
        try await wait("initial telemetry") { model.telemetry != nil }
        try require(!proxyFetch(origin, through: listener), "global mode did not use the selected fixture node")
        model.selectRoutingMode(.rule)
        try await wait("rule mode") { !model.busy }
        try require(model.routingMode == .rule && proxyFetch(origin, through: listener), "rule mode did not apply the loopback policy")
        model.selectRoutingMode(.direct)
        try await wait("direct mode") { !model.busy }
        try require(model.routingMode == .direct && proxyFetch(origin, through: listener), "direct mode did not connect to the loopback origin")
        model.selectRoutingMode(.global)
        try await wait("global mode") { !model.busy }
        try require(model.routingMode == .global && model.proxyAddress == listener && !proxyFetch(origin, through: listener),
                    "returning to global mode did not preserve the listening address and selected node")
        model.publishPAC(toSystem: false)
        try await wait("local PAC endpoint") { !model.pac.busy }
        guard let endpoint = model.pac.localURL, let endpointPort = endpoint.port.flatMap(UInt16.init(exactly:)) else {
            throw CheckFailed("local PAC could not start")
        }
        try require(endpoint.host == "127.0.0.1" && !model.pac.hasLiveOwnership, "local PAC should leave macOS proxy settings untouched")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 5
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        let client = URLSession(configuration: config)
        defer { client.finishTasksAndInvalidate() }
        let (data, response) = try await client.data(from: endpoint)
        let expected = try model.pac.policy.makeScript(proxyPort: port)
        try require((response as? HTTPURLResponse)?.statusCode == 200 && data == Data(expected.utf8), "local PAC did not serve the current workspace policy")

        model.refreshSubscription(source)
        try await wait("changed subscription") { !model.fetchingSubscription }
        try require(model.sourceChangePending, "refresh was not staged while proxy was running")
        try require(model.proxyAddress == listener && canConnect(to: localPort), "refresh interrupted the live listener")
        try require(model.nodes.map(\.name) == ["local"], "refresh replaced nodes in the live session")

        model.refreshSubscription(source)
        try await wait("failed subscription request") { !model.fetchingSubscription }
        try require(model.sourceChangePending && model.nodes.map(\.name) == ["local"], "failed refresh lost the staged list or changed the running list")
        try require(model.subscriptionMessage.contains("503") && !model.subscriptionMessage.contains(token), "error did not retain useful diagnostics or leaked the URL token")
        try require(model.proxyAddress == listener && canConnect(to: localPort), "failed refresh interrupted the live listener")

        model.stop()
        try require(!model.running && !canConnect(to: localPort), "stop did not release the proxy listener")
        try await wait("PAC listener shutdown") { model.pac.localURL == nil && !canConnect(to: endpointPort) }
        try require(model.telemetry == nil, "stop retained the previous session's telemetry")
        try require(!model.sourceChangePending && model.nodes.map(\.name) == ["replaced"], "stop did not apply the last successful refresh")

        let reloaded = Workspace(store: store, pac: model.pac)
        try require(reloaded.selectedSubscription == source && reloaded.nodes.map(\.name) == ["replaced"], "a new workspace did not load the last successful subscription from disk")
        let manager = FileManager.default
        let file = directory.appendingPathComponent("subscriptions.json")
        let dirMode = try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let fileMode = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        try require(dirMode == 0o700 && fileMode == 0o600, "credential catalog permissions are not private")
    }

    @MainActor private static func checkBackgroundHealth(_ model: Workspace) async throws {
        model.monitorHealth()
        model.start()
        try await wait("Mihomo restart") { model.running || !model.busy }
        guard let listener = model.proxyAddress,
              let port = URL(string: listener)?.port, let localPort = UInt16(exactly: port) else {
            throw CheckFailed("synthetic Mihomo did not restart")
        }
        try require(canConnect(to: localPort), "test listener is not available before synthetic crash")
        let pid = try ownedEnginePID()
        try require(kill(pid, SIGKILL) == 0, "could not terminate the owned synthetic child")
        try await wait("background health detection") { !model.running && model.status.contains("Mihomo 已退出") }
        try require(model.proxyAddress == nil && !canConnect(to: localPort), "background recovery left stale listener state")
    }

    private static func ownedEnginePID() throws -> pid_t {
        // The checks executable launches a verified private runtime copy.
        var children = [pid_t](repeating: 0, count: 16)
        let count = children.withUnsafeMutableBytes { proc_listchildpids(getpid(), $0.baseAddress, Int32($0.count)) }
        guard count > 0 && count < children.count else { throw CheckFailed("could not enumerate owned children") }
        let matching = children.prefix(Int(count)).filter { pid in
            var path = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0 else { return false }
            let executable = URL(filePath: String(cString: path)).resolvingSymlinksInPath()
            return executable.lastPathComponent == "mihomo" && executable.deletingLastPathComponent().lastPathComponent.hasPrefix("clay-runtime-")
        }
        guard matching.count == 1, let pid = matching.first else { throw CheckFailed("could not identify exactly one owned synthetic Mihomo") }
        return pid
    }

    private static func proxyFetch(_ origin: String, through listener: String) -> Bool {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/curl")
        p.arguments = ["-q", "--fail", "--silent", "--max-time", "2", "--noproxy", "", "--proxy", listener, origin + "/plain"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    @MainActor private static func wait(_ activity: String, until isDone: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !isDone() {
            guard ContinuousClock.now < deadline else { throw CheckFailed("timed out waiting for \(activity)") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw CheckFailed(description) }
    }

    private static func canConnect(to port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(address.sin_len)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, size) == 0 }
        }
    }
}
