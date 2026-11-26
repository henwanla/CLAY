import CLAYCore
import CryptoKit
import Foundation
import Security

struct LabSubscriptionSummary: Identifiable {
    let id: UUID
    // A missing count denotes an unreadable record that can still be deleted.
    let name: String
    let count: Int?
    let updated: Date?
}

enum LabSubscriptionError: Error {
    case invalidAddress, invalidContent, storage, changed
}

protocol LabSubscriptionKey: Sendable {
    func load() throws -> SymmetricKey?
    func createIfAbsent() throws -> SymmetricKey
}

struct LabKeychainSubscriptionKey: LabSubscriptionKey {
    let service: String

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "catalog-key-v1",
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> SymmetricKey? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &found)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = found as? Data, data.count == 32 else {
            throw LabSubscriptionError.storage
        }
        return SymmetricKey(data: data)
    }

    func createIfAbsent() throws -> SymmetricKey {
        let candidate = SymmetricKey(size: .bits256)
        var added = item
        added[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        added[kSecValueData as String] = candidate.withUnsafeBytes { Data($0) }
        switch SecItemAdd(added as CFDictionary, nil) {
        case errSecSuccess: return candidate
        case errSecDuplicateItem:
            guard let existing = try load() else { throw LabSubscriptionError.storage }
            return existing
        default: throw LabSubscriptionError.storage
        }
    }
}

/// The app owns the catalog. The extension only receives the chosen node as
/// session data. Neither UserDefaults nor VPN preferences receive a URL or body.
actor LabSubscriptionStore {
    struct Download: Sendable {
        let content: Data
        let count: Int

        init(content: String, count: Int) throws {
            guard (1...ProfileImporter.maxBytes).contains(content.utf8.count), count > 0 else {
                throw LabSubscriptionError.invalidContent
            }
            self.content = Data(content.utf8)
            self.count = count
        }
    }

    private struct Record: Codable {
        let name: String
        let address: URL
        let content: Data
        let count: Int
        let updated: Date

        var downloadText: String? {
            guard (1...ProfileImporter.maxBytes).contains(content.count), count > 0 else { return nil }
            return String(data: content, encoding: .utf8)
        }
    }

    static let live = LabSubscriptionStore(
        directory: URL.applicationSupportDirectory.appendingPathComponent("CLAY-Subscriptions", isDirectory: true),
        key: LabKeychainSubscriptionKey(service: (Bundle.main.bundleIdentifier ?? "app.clay.tunnellab") + ".subscriptions"),
        fetch: { address in
            let result = try await SubscriptionImporter.fetch(address)
            return try Download(content: result.content, count: result.imported.profiles.count)
        }
    )

    private static let header = Data("CLAY-IOS-SUB".utf8) + Data([0, 1])
    private static let maxStoredBytes = 4 * 1024 * 1024
    private let directory: URL
    private let key: any LabSubscriptionKey
    private let fetch: @Sendable (URL) async throws -> Download
    private var refreshTickets: [UUID: UUID] = [:]

    init(directory: URL, key: any LabSubscriptionKey, fetch: @escaping @Sendable (URL) async throws -> Download) {
        self.directory = directory
        self.key = key
        self.fetch = fetch
    }

    func summaries() throws -> [LabSubscriptionSummary] {
        let ids = try recordIDs()
        let cachedKey = try? key.load()
        return ids.map { id in
            let record = cachedKey.flatMap { try? read(id, key: $0) }
            return LabSubscriptionSummary(id: id, name: record?.name ?? "", count: record?.count, updated: record?.updated)
        }.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    func add(name: String, address: String) async throws {
        let url = try Self.https(address)
        let imported = try await fetch(url)
        try Task.checkCancellation()
        let ids = try recordIDs()
        let localKey: SymmetricKey
        if let existing = try key.load() { localKey = existing }
        else {
            guard ids.isEmpty else { throw LabSubscriptionError.storage }
            localKey = try key.createIfAbsent()
        }
        let prefix = name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(80)
        let label = String(String.UnicodeScalarView(prefix.filter { !CharacterSet.controlCharacters.contains($0) }))
        let record = Record(name: label, address: url, content: imported.content, count: imported.count, updated: Date())
        try write(record, id: UUID(), key: localKey)
    }

    func refresh(_ id: UUID) async throws {
        guard let localKey = try key.load() else { throw LabSubscriptionError.storage }
        let record = try read(id, key: localKey)
        let ticket = UUID()
        refreshTickets[id] = ticket
        defer { if refreshTickets[id] == ticket { refreshTickets[id] = nil } }
        let imported = try await fetch(try Self.https(record.address.absoluteString))
        try Task.checkCancellation()
        guard refreshTickets[id] == ticket else { throw LabSubscriptionError.changed }
        try write(Record(name: record.name, address: record.address, content: imported.content,
                         count: imported.count, updated: Date()), id: id, key: localKey)
    }

    func load(_ id: UUID) throws -> String {
        guard let localKey = try key.load(), let text = try read(id, key: localKey).downloadText else {
            throw LabSubscriptionError.storage
        }
        return text
    }

    func remove(_ id: UUID) throws {
        refreshTickets[id] = nil
        do { try FileManager.default.removeItem(at: location(id)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
    }

    static func https(_ address: String) throws -> URL {
        guard let url = try? SubscriptionImporter.validatedURL(address), url.scheme?.lowercased() == "https" else {
            throw LabSubscriptionError.invalidAddress
        }
        return url
    }

    private func recordIDs() throws -> [UUID] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap {
                $0.pathExtension == "claysub" ? UUID(uuidString: $0.deletingPathExtension().lastPathComponent) : nil
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return [] }
    }

    private func location(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".claysub") }

    private func authenticatedBytes(_ id: UUID) -> Data { Self.header + Data(id.uuidString.utf8) }

    private func read(_ id: UUID, key: SymmetricKey) throws -> Record {
        let file = try FileHandle(forReadingFrom: location(id))
        defer { try? file.close() }
        guard let data = try file.read(upToCount: Self.maxStoredBytes + 1), data.count <= Self.maxStoredBytes,
              data.starts(with: Self.header) else { throw LabSubscriptionError.storage }
        let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(Self.header.count)))
        let payload = try AES.GCM.open(box, using: key, authenticating: authenticatedBytes(id))
        let record = try JSONDecoder().decode(Record.self, from: payload)
        guard record.downloadText != nil else { throw LabSubscriptionError.storage }
        return record
    }

    private func write(_ record: Record, id: UUID, key: SymmetricKey) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let box = try AES.GCM.seal(encoder.encode(record), using: key, authenticating: authenticatedBytes(id))
        guard let combined = box.combined, Self.header.count + combined.count <= Self.maxStoredBytes else {
            throw LabSubscriptionError.storage
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try (Self.header + combined).write(to: location(id), options: options)
    }
}
