import Foundation

final class TestSubscriptionKeyStore: SubscriptionKeyStore {
    var key: Data?
    var blocked = false
    var beforeCreate: (() throws -> Void)?
    private(set) var createCalls = 0

    init(key: Data? = nil) { self.key = key }

    func load() throws -> Data? {
        if blocked { throw SubscriptionStorageError.invalidKey }
        return key
    }

    func createIfAbsent() throws -> Data {
        createCalls += 1
        if blocked { throw SubscriptionStorageError.invalidKey }
        try beforeCreate?()
        let key = key ?? Data(repeating: 42, count: 32)
        self.key = key
        return key
    }
}

enum SubscriptionStorageChecks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clay-storage-check-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try testMigrationAndReload(root)
        try testCorruptAndUnavailableKeys(root)
        try testFailedLegacyMigration(root)
        try testOptimisticSave(root)
        try testLocalKeyBackend(root)
        print("PASS encrypted subscription catalog migration, authentication, recovery, and atomic updates")
    }

    private static let header = Data("CLAY-SUBSCRIPTIONS\0".utf8) + Data([1])
    private static let bodyMarker = "synthetic-private-subscription-body"
    private static let queryMarker = "synthetic-private-url-token"

    private static func fixture(_ label: String = "Fixture") -> SubscriptionCatalog {
        let id = UUID()
        return SubscriptionCatalog(entries: [.init(id: id, name: label,
            url: URL(string: "https://example.test/sub?token=\(queryMarker)")!,
            content: bodyMarker, updated: Date(timeIntervalSince1970: 1_720_000_000))], selected: id)
    }

    private static func testMigrationAndReload(_ root: URL) throws {
        let dir = root.appendingPathComponent("migrate", isDirectory: true)
        let path = dir.appendingPathComponent("subscriptions.json")
        let old = fixture()
        try legacy(old, to: path)
        let keys = TestSubscriptionKeyStore()
        let store = SubscriptionStore(directory: dir, keyStore: keys)
        try expectCatalog(try store.load(), sameAs: old)
        let encrypted = try Data(contentsOf: path)
        try expectEncrypted(encrypted)
        try expect(try mode(dir) == 0o700 && mode(path) == 0o600, "private catalog permissions")
        let nextStore = SubscriptionStore(directory: dir, keyStore: keys)
        try expectCatalog(try nextStore.load(), sameAs: old)
        try expect(try Data(contentsOf: path) == encrypted, "encrypted reopen rewrote the file")
        try nextStore.save(old)
        try expect(try Data(contentsOf: path) != encrypted, "saving identical contents did not use a fresh nonce")
        try expect(keys.createCalls == 1, "encrypted reopen or update attempted to create a key")
        try expect(try Set(FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["subscriptions.json", ".catalog.lock"], "migration retained an extra copy")
    }

    private static func testCorruptAndUnavailableKeys(_ root: URL) throws {
        let dir = root.appendingPathComponent("authenticate", isDirectory: true)
        let path = dir.appendingPathComponent("subscriptions.json")
        let old = fixture()
        let keys = TestSubscriptionKeyStore()
        let store = SubscriptionStore(directory: dir, keyStore: keys)
        try expect(try store.load().entries.isEmpty, "missing catalog must be empty")
        try expect(!FileManager.default.fileExists(atPath: dir.path) && keys.createCalls == 0, "empty load persisted data or requested a key")
        try store.save(old)
        let original = try Data(contentsOf: path)
        let correctKey = keys.key

        keys.key = nil
        try rejects(.keyMissing) { try store.save(fixture("new")) }
        try rejects(.keyMissing) { _ = try store.load() }
        try rejects(.catalogChanged) { try store.save(fixture("new")) }
        try expect(try keys.createCalls == 1 && Data(contentsOf: path) == original, "missing key replaced the catalog or created a replacement")

        keys.key = Data(repeating: 7, count: 32)
        try rejects(.unreadableCatalog) { _ = try store.load() }
        keys.key = correctKey
        try expectCatalog(try store.load(), sameAs: old)
        keys.blocked = true
        try rejects(.invalidKey) { try store.save(fixture("new")) }
        keys.blocked = false

        var tampered = original
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        try tampered.write(to: path)
        try rejects(.unreadableCatalog) { _ = try store.load() }
        try rejects(.catalogChanged) { try store.save(fixture("new")) }
        try expect(try Data(contentsOf: path) == tampered, "failed authentication replaced the original bytes")

        var future = original
        future[header.count - 1] = 2
        try future.write(to: path)
        try rejects(.unsupportedFormat) { _ = try store.load() }
        try expect(try Data(contentsOf: path) == future, "future version was changed")

        try FileManager.default.removeItem(at: path)
        try rejects(.catalogChanged) { try store.save(fixture("Implicit reset")) }
        try expect(!FileManager.default.fileExists(atPath: path.path), "unreadable revision silently created a new catalog")
    }

    private static func testFailedLegacyMigration(_ root: URL) throws {
        let dir = root.appendingPathComponent("legacy-failure", isDirectory: true)
        let path = dir.appendingPathComponent("subscriptions.json")
        let old = fixture()
        try legacy(old, to: path)
        let original = try Data(contentsOf: path)
        let keys = TestSubscriptionKeyStore()
        keys.blocked = true
        let store = SubscriptionStore(directory: dir, keyStore: keys)
        try rejects(.invalidKey) { _ = try store.load() }
        try rejects(.catalogChanged) { try store.save(fixture("new")) }
        try expect(try Data(contentsOf: path) == original, "key error modified old JSON")

        let malformed = Data("{\"entries\":".utf8)
        try malformed.write(to: path)
        try rejects(.unreadableCatalog) { _ = try store.load() }
        try expect(try keys.createCalls == 1 && Data(contentsOf: path) == malformed, "malformed legacy JSON called the key store or was overwritten")

        try original.write(to: path)
        keys.blocked = false
        // Block the final rename with a directory after reading the legacy
        // file. This simulates a write failure without destroying old bytes.
        let backup = dir.appendingPathComponent("test-held-original")
        keys.beforeCreate = {
            let files = FileManager.default
            try files.moveItem(at: path, to: backup)
            try files.createDirectory(at: path, withIntermediateDirectories: false)
        }
        try rejects(.fileAccess) { _ = try store.load() }
        try expect(try Data(contentsOf: backup) == original, "failed replacement damaged the legacy data")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        try expect(!remaining.contains { $0.hasSuffix(".tmp") }, "a failed replacement left a temporary file")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: backup, to: path)
        keys.beforeCreate = nil
        try expectCatalog(try store.load(), sameAs: old)
    }

    private static func testOptimisticSave(_ root: URL) throws {
        let dir = root.appendingPathComponent("parallel", isDirectory: true)
        let keys = TestSubscriptionKeyStore()
        let first = SubscriptionStore(directory: dir, keyStore: keys)
        let second = SubscriptionStore(directory: dir, keyStore: keys)
        _ = try second.load()
        let one = fixture("First")
        try first.save(one)
        try rejects(.catalogChanged) { try second.save(fixture("Empty overwrite")) }
        try expectCatalog(try second.load(), sameAs: one)
        let two = fixture("Second")
        try second.save(two)
        try rejects(.catalogChanged) { try first.save(fixture("Stale overwrite")) }
        try expectCatalog(try first.load(), sameAs: two)
    }

    private static func testLocalKeyBackend(_ root: URL) throws {
        let catalogFolder = root.appendingPathComponent("catalog", isDirectory: true)
        let keyFolder = root.appendingPathComponent("separate-key", isDirectory: true)
        let keyFile = keyFolder.appendingPathComponent("subscriptions.key")
        let keys = LocalSubscriptionKeyStore(directory: keyFolder)
        try expect(try keys.load() == nil, "missing local key returned bytes")
        let a = try keys.createIfAbsent()
        try expect(try a.count == 32 && keys.createIfAbsent() == a, "key storage was not stable")
        try expect(try mode(keyFolder) == 0o700 && mode(keyFile) == 0o600, "local key permissions")
        let store = SubscriptionStore(directory: catalogFolder, keyStore: keys)
        try store.save(fixture())
        try expect(!FileManager.default.fileExists(atPath: catalogFolder.appendingPathComponent("subscriptions.key").path), "catalog includes the key")

        let saved = keyFolder.appendingPathComponent("test-held-key")
        try FileManager.default.moveItem(at: keyFile, to: saved)
        try rejects(.keyMissing) { _ = try store.load() }
        try rejects(.catalogChanged) { try store.save(fixture()) }
        try expect(!FileManager.default.fileExists(atPath: keyFile.path), "existing encrypted catalog recreated a lost key")
        try FileManager.default.createSymbolicLink(at: keyFile, withDestinationURL: saved)
        try rejects(.invalidKey) { _ = try store.load() }
        try rejects(.invalidKey) { _ = try keys.createIfAbsent() }
        try FileManager.default.removeItem(at: keyFile)
        try FileManager.default.moveItem(at: saved, to: keyFile)
        try expect(try store.load().entries.count == 1, "restored key could not recover the catalog")
    }

    private static func legacy(_ catalog: SubscriptionCatalog, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: path)
    }

    private static func mode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    private static func expectEncrypted(_ data: Data) throws {
        try expect(data.starts(with: header), "missing versioned encryption header")
        try expect(data.range(of: Data(bodyMarker.utf8)) == nil && data.range(of: Data(queryMarker.utf8)) == nil, "catalog stored cleartext credentials")
    }

    private static func expectCatalog(_ actual: SubscriptionCatalog, sameAs expected: SubscriptionCatalog) throws {
        try expect(actual.selected == expected.selected && actual.entries.count == expected.entries.count, "selection or entry count changed")
        for (a, b) in zip(actual.entries, expected.entries) {
            try expect(a.id == b.id && a.name == b.name && a.url == b.url && a.content == b.content && a.updated == b.updated, "catalog did not round-trip")
        }
    }

    private static func rejects(_ expected: SubscriptionStorageError, _ body: () throws -> Void) throws {
        do { try body() }
        catch let actual as SubscriptionStorageError {
            try expect(actual == expected, "unexpected error: \(actual); expected \(expected)")
            return
        }
        throw Failure("accepted an invalid catalog or key")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ explanation: String) throws {
        guard try condition() else { throw Failure(explanation) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
