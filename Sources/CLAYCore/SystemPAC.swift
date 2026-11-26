#if os(macOS)
import Foundation
import Security
import SystemConfiguration

public struct SystemPACService: Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let isPrimary: Bool

    public init(id: String, name: String, isPrimary: Bool) {
        self.id = id; self.name = name; self.isPrimary = isPrimary
    }
}

public enum SystemPACRestoreResult: Equatable, Sendable {
    case restored, externallyChanged, noBackup
}

public enum SystemPACError: LocalizedError {
    case invalidURL, chooseService, serviceUnavailable, externallyChanged, authorizationDenied
    case backupUnavailable, recoveryRequired, restorationPending, configuration(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "系统 PAC 只接受带有端口和独立路径的本机 HTTP 地址。"
        case .chooseService: return "未找到可用的主要网络服务，请明确选择一个网络服务。"
        case .serviceUnavailable: return "所选网络服务已停用或不可用，请重新选择。"
        case .externallyChanged: return "PAC 设置已在系统中更改。请先检查或恢复原设置，再重新启用。"
        case .authorizationDenied: return "macOS 没有授予修改网络配置的权限，请在前台重试。"
        case .backupUnavailable: return "无法读取或保存 PAC 恢复记录。请检查 CLAY 应用支持目录。"
        case .recoveryRequired: return "上次修改可能仍在生效。请先使用「恢复系统代理」确认并恢复设置。"
        case .restorationPending: return "macOS 仍在使用 CLAY 的 PAC 地址。请稍等片刻，再试一次恢复。"
        case .configuration(let status): return "macOS 网络设置操作失败（\(status)）。请稍后重试。"
        }
    }
}

@_spi(Checks) public protocol SystemPACBackend: AnyObject {
    func withLocked<T>(interactive: Bool, _ body: (any SystemPACSession) throws -> T) throws -> T
    /// Effective system settings only; this read must not request privileges.
    func effectivePACURLs() -> Set<String>
}

@_spi(Checks) public protocol SystemPACSession {
    func services() -> [SystemPACService]
    /// nil means the service or its proxy protocol no longer exists.
    func preferences(serviceID: String) throws -> [String: Any]?
    func commit(_ values: [String: Any], serviceID: String) throws
    func apply() throws
    /// URLs of enabled PAC configurations in the effective or service state.
    func activePACURLs(serviceID: String) -> Set<String>
}

@MainActor public final class SystemPACManager {
    private enum Phase: String, Codable { case installing, active, updating, restoring }
    private struct Journal: Codable {
        let service: SystemPACService
        let originalValues: Data
        let changedKeys: [String]
        var phase: Phase
        var url: String
        var previousURL: String?

        var ownedURLs: Set<String> { Set([url, previousURL].compactMap { $0 }) }
    }

    private static let pacURL = kSCPropNetProxiesProxyAutoConfigURLString as String
    private static let pacEnable = kSCPropNetProxiesProxyAutoConfigEnable as String
    private static let conflictingFlags = [kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPSEnable,
                                           kSCPropNetProxiesSOCKSEnable, kSCPropNetProxiesProxyAutoDiscoveryEnable].map { $0 as String }

    private let backend: any SystemPACBackend
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("backup-v1.plist") }
    private var liveURLs: Set<String> = []
    public private(set) var managedService: SystemPACService?

    public convenience init() {
        self.init(backend: MacSystemPACBackend(), journalDirectory: URL.applicationSupportDirectory
            .appendingPathComponent("CLAY", isDirectory: true).appendingPathComponent("SystemPAC", isDirectory: true))
    }

    @_spi(Checks) public init(backend: any SystemPACBackend, journalDirectory: URL) {
        self.backend = backend; directory = journalDirectory
    }

    public static func services() -> [SystemPACService] {
        guard let prefs = SCPreferencesCreate(nil, "CLAY" as CFString, nil) else { return [] }
        return MacSystemPACSession(prefs: prefs).services()
    }

    public func pendingRecovery() throws -> SystemPACService? { try load()?.service }

    /// A committed network service and the system's current proxy settings may
    /// differ while configd catches up, after a network switch, or after edits.
    public func isEffective(url: URL) -> Bool {
        managedService != nil && liveURLs.contains(url.absoluteString) && backend.effectivePACURLs().contains(url.absoluteString)
    }

    public func needsListener(at url: URL) -> Bool {
        liveURLs.contains(url.absoluteString) || ((try? load())?.ownedURLs.contains(url.absoluteString) ?? false)
    }

    @discardableResult public func enable(url: URL, serviceID: String? = nil) throws -> SystemPACService {
        let address = try Self.loopbackAddress(url)
        guard try load() == nil else { throw SystemPACError.recoveryRequired }
        return try backend.withLocked(interactive: true) { session in
            guard try load() == nil else { throw SystemPACError.recoveryRequired }
            let choices = session.services()
            let selected: SystemPACService
            if let serviceID {
                guard let service = choices.first(where: { $0.id == serviceID }) else { throw SystemPACError.serviceUnavailable }
                selected = service
            } else {
                guard let service = choices.first(where: \.isPrimary) else { throw SystemPACError.chooseService }
                selected = service
            }
            guard var values = try session.preferences(serviceID: selected.id) else { throw SystemPACError.serviceUnavailable }
            guard values[Self.pacURL] as? String != address else { throw SystemPACError.externallyChanged }
            var changes: [String: Any] = [Self.pacURL: address, Self.pacEnable: 1]
            for key in Self.conflictingFlags where (values[key] as? NSNumber)?.intValue ?? 0 != 0 { changes[key] = 0 }
            changes = changes.filter { !Self.equal(values[$0.key], $0.value) }
            let originals = values.filter { changes.keys.contains($0.key) }
            var journal = Journal(service: selected,
                originalValues: try PropertyListSerialization.data(fromPropertyList: originals, format: .binary, options: 0),
                changedKeys: changes.keys.sorted(), phase: .installing, url: address)
            values.merge(changes) { _, replacement in replacement }
            try save(journal)
            liveURLs = journal.ownedURLs
            do {
                try session.commit(values, serviceID: selected.id)
                try session.apply()
                journal.phase = .active
                try save(journal)
            } catch { throw SystemPACError.recoveryRequired }
            managedService = selected
            return selected
        }
    }

    @discardableResult public func update(url: URL) throws -> SystemPACService {
        let address = try Self.loopbackAddress(url)
        guard let service = managedService else { throw SystemPACError.recoveryRequired }
        return try backend.withLocked(interactive: true) { session in
            guard var journal = try load(), journal.service.id == service.id, journal.phase == .active,
                  liveURLs == journal.ownedURLs else { throw SystemPACError.recoveryRequired }
            guard session.services().contains(where: { $0.id == service.id }),
                  var values = try session.preferences(serviceID: service.id),
                  values[Self.pacURL] as? String == journal.url, Self.equal(values[Self.pacEnable], 1)
            else { throw SystemPACError.externallyChanged }
            if address == journal.url { return service }
            journal.phase = .updating
            journal.previousURL = journal.url
            journal.url = address
            try save(journal)
            liveURLs = journal.ownedURLs
            values[Self.pacURL] = address
            do {
                try session.commit(values, serviceID: service.id)
                try session.apply()
                journal.phase = .active
                journal.previousURL = nil
                try save(journal)
            } catch { throw SystemPACError.recoveryRequired }
            liveURLs = journal.ownedURLs
            return service
        }
    }

    @discardableResult public func restore(interactive: Bool = true) throws -> SystemPACRestoreResult {
        guard try load() != nil else {
            if !liveURLs.isEmpty { throw SystemPACError.backupUnavailable }
            return .noBackup
        }
        return try backend.withLocked(interactive: interactive) { session in
            guard var journal = try load() else {
                if !liveURLs.isEmpty { throw SystemPACError.backupUnavailable }
                return .noBackup
            }
            let id = journal.service.id
            let current = try session.preferences(serviceID: id)
            let address = current?[Self.pacURL] as? String
            var result: SystemPACRestoreResult = .externallyChanged
            if var values = current, let address, journal.ownedURLs.contains(address) {
                let originals = try Self.originals(in: journal)
                for key in journal.changedKeys {
                    let installed: Any = key == Self.pacURL ? address as Any : (key == Self.pacEnable ? 1 : 0)
                    // An external edit to one key does not prevent restoring other owned keys.
                    if Self.equal(values[key], installed) { values[key] = originals[key] }
                }
                journal.phase = .restoring
                try save(journal)
                try session.commit(values, serviceID: id)
                try session.apply()
                result = .restored
            } else if journal.phase == .restoring || !session.activePACURLs(serviceID: id).isDisjoint(with: journal.ownedURLs) {
                // A crash or failed Apply may leave the dynamic store on an old URL
                // even if preferences already reflect the original or an external edit.
                try session.apply()
                if journal.phase == .restoring { result = .restored }
            } else if journal.phase == .installing {
                let originals = try Self.originals(in: journal)
                if journal.changedKeys.allSatisfy({ Self.equal(current?[$0], originals[$0]) }) { result = .noBackup }
            }
            // Apply can return before configd publishes the new state. Retain the
            // journal and listener ownership so the caller can retry after it settles.
            guard session.activePACURLs(serviceID: id).isDisjoint(with: journal.ownedURLs) else {
                throw SystemPACError.restorationPending
            }
            do { try FileManager.default.removeItem(at: file) }
            catch { throw SystemPACError.backupUnavailable }
            liveURLs.removeAll(); managedService = nil
            return result
        }
    }

    private static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return (lhs as? NSObject)?.isEqual(rhs) == true
    }

    private static func loopbackAddress(_ url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "http",
              parts.host == "127.0.0.1", let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath.count > 1 else { throw SystemPACError.invalidURL }
        return url.absoluteString
    }

    private static func originals(in journal: Journal) throws -> [String: Any] {
        guard let values = try? PropertyListSerialization.propertyList(from: journal.originalValues, options: [], format: nil) as? [String: Any],
              values.keys.allSatisfy({ journal.changedKeys.contains($0) }) else { throw SystemPACError.backupUnavailable }
        return values
    }

    private func load() throws -> Journal? {
        do {
            let value = try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: file))
            let keys = Set(value.changedKeys)
            let allowed = Set([Self.pacURL, Self.pacEnable] + Self.conflictingFlags)
            guard !value.service.id.isEmpty, keys.isSubset(of: allowed), keys.contains(Self.pacURL),
                  value.ownedURLs.allSatisfy({ value in
                      guard let url = URL(string: value) else { return false }
                      return (try? Self.loopbackAddress(url)) == value
                  }) else { throw SystemPACError.backupUnavailable }
            _ = try Self.originals(in: value)
            return value
        } catch CocoaError.fileReadNoSuchFile { return nil }
        catch { throw SystemPACError.backupUnavailable }
    }

    private func save(_ value: Journal) throws {
        do {
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? files.removeItem(at: temporary) }
            let data = try PropertyListEncoder().encode(value)
            guard files.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, file.path) == 0 else { throw SystemPACError.backupUnavailable }
        } catch { throw SystemPACError.backupUnavailable }
    }
}

private final class MacSystemPACBackend: SystemPACBackend {
    private var authorization: AuthorizationRef?

    deinit { if let authorization { AuthorizationFree(authorization, []) } }

    func effectivePACURLs() -> Set<String> { MacSystemPACSession.effectivePACURLs() }

    func withLocked<T>(interactive: Bool, _ body: (any SystemPACSession) throws -> T) throws -> T {
        // SystemConfiguration's privileged helper can request interactive rights
        // itself. Do not call it from a background health check.
        guard interactive else { throw SystemPACError.authorizationDenied }
        if authorization == nil {
            let status = AuthorizationCreate(nil, nil, [], &authorization)
            guard status == errAuthorizationSuccess else { throw SystemPACError.authorizationDenied }
        }
        guard let authorization else { throw SystemPACError.authorizationDenied }
        // Let SystemConfiguration acquire its own right so CLAY does not create
        // a separate authorization prompt before the actual operation.
        guard let prefs = SCPreferencesCreateWithAuthorization(nil, "CLAY" as CFString, nil, authorization),
              SCPreferencesLock(prefs, false) else {
            let status = SCError()
            throw status == kSCStatusAccessError ? SystemPACError.authorizationDenied : SystemPACError.configuration(status)
        }
        defer { SCPreferencesUnlock(prefs) }
        return try body(MacSystemPACSession(prefs: prefs))
    }
}

private struct MacSystemPACSession: SystemPACSession {
    let prefs: SCPreferences

    func services() -> [SystemPACService] {
        guard let set = SCNetworkSetCopyCurrent(prefs),
              let network = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return [] }
        let eligible = network.filter {
            SCNetworkServiceGetEnabled($0) && SCNetworkServiceCopyProtocol($0, kSCNetworkProtocolTypeProxies).map(SCNetworkProtocolGetEnabled) == true
        }
        let ids = Set(eligible.compactMap { SCNetworkServiceGetServiceID($0) as String? })
        let primary = [kSCEntNetIPv4, kSCEntNetIPv6].compactMap { entity -> String? in
            let key = SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, entity)
            return (SCDynamicStoreCopyValue(nil, key) as? [String: Any])?[kSCDynamicStorePropNetPrimaryService as String] as? String
        }.first(where: ids.contains)
        return eligible.compactMap { service -> SystemPACService? in
            guard let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
            return SystemPACService(id: id, name: SCNetworkServiceGetName(service) as String? ?? id, isPrimary: id == primary)
        }.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func preferences(serviceID: String) throws -> [String: Any]? {
        guard let proxy = proxyProtocol(serviceID: serviceID) else { return nil }
        return SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] ?? [:]
    }

    func commit(_ values: [String: Any], serviceID: String) throws {
        guard let proxy = proxyProtocol(serviceID: serviceID) else { throw SystemPACError.serviceUnavailable }
        guard SCNetworkProtocolSetConfiguration(proxy, values.isEmpty ? nil : values as CFDictionary),
              SCPreferencesCommitChanges(prefs) else { throw SystemPACError.configuration(SCError()) }
    }

    func apply() throws {
        guard SCPreferencesApplyChanges(prefs) else { throw SystemPACError.configuration(SCError()) }
    }

    func activePACURLs(serviceID: String) -> Set<String> {
        let serviceKey = SCDynamicStoreKeyCreateNetworkServiceEntity(nil, kSCDynamicStoreDomainState,
                                                                      serviceID as CFString, kSCEntNetProxies)
        let effective = (SCDynamicStoreCopyProxies(nil) as? [String: Any]).map(Self.enabledPACURLs) ?? []
        let service = SCDynamicStoreCopyValue(nil, serviceKey) as? [String: Any]
        return effective.union(service.map(Self.enabledPACURLs) ?? [])
    }

    static func effectivePACURLs() -> Set<String> {
        guard let values = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return [] }
        // The top-level dictionary covers default settings. Scoped entries may
        // still mention CLAY after a switch to a different default service.
        return Set([enabledPACURL(values)].compactMap { $0 })
    }

    private static func enabledPACURL(_ values: [String: Any]) -> String? {
        guard (values[kSCPropNetProxiesProxyAutoConfigEnable as String] as? NSNumber)?.boolValue == true else { return nil }
        return values[kSCPropNetProxiesProxyAutoConfigURLString as String] as? String
    }

    private static func enabledPACURLs(_ values: [String: Any]) -> Set<String> {
        var addresses = Set<String>()
        func collect(_ values: [String: Any]) {
            if let url = enabledPACURL(values) { addresses.insert(url) }
            if let scoped = values["__SCOPED__"] as? [String: [String: Any]] { scoped.values.forEach(collect) }
            if let services = values["__SERVICES__"] as? [String: [String: Any]] { services.values.forEach(collect) }
            if let supplemental = values["__SUPPLEMENTAL__"] as? [[String: Any]] { supplemental.forEach(collect) }
        }
        collect(values)
        return addresses
    }

    private func proxyProtocol(serviceID: String) -> SCNetworkProtocol? {
        guard let service = SCNetworkServiceCopy(prefs, serviceID as CFString) else { return nil }
        return SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
    }
}
#endif
