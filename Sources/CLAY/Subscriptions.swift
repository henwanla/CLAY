import CryptoKit
import Darwin
import Foundation

struct SubscriptionSummary: Identifiable {
    let id: UUID
    let name: String
    let count: Int
    let updated: Date
}

struct SubscriptionCatalog: Codable {
    struct Entry: Codable {
        let id: UUID
        let name: String
        let url: URL
        var content: String
        var updated: Date
    }

    var entries: [Entry] = []
    var selected: UUID?
}

/// The catalog contains credentials in both the URL and downloaded body. Only
/// SubscriptionSummary is exposed to views; neither field goes into reports.
final class SubscriptionStore {
    private static let file = "subscriptions.json"
    private static let magic = Data("CLAY-SUBSCRIPTIONS\0".utf8)
    private static let header = magic + Data([1])
    private static let base = URL.applicationSupportDirectory.appendingPathComponent("CLAY", isDirectory: true)

    private let directory: URL
    private let keyStore: any SubscriptionKeyStore
    private let mutex = NSLock()
    private var revision = Revision.absent

    private enum Revision: Equatable {
        case unreadable
        case absent
        case written(SHA256.Digest)

        init(_ record: Data?) {
            self = record.map { .written(SHA256.hash(data: $0)) } ?? .absent
        }
    }

    convenience init() {
        self.init(directory: Self.base.appendingPathComponent("Subscriptions", isDirectory: true),
                  keyStore: LocalSubscriptionKeyStore(directory: Self.base.appendingPathComponent("Private", isDirectory: true)))
    }

    init(directory: URL, keyStore: any SubscriptionKeyStore) {
        self.directory = directory
        self.keyStore = keyStore
    }

    func load() throws -> SubscriptionCatalog {
        mutex.lock(); defer { mutex.unlock() }
        revision = .unreadable
        guard let folder = try PrivateSubscriptionFiles(directory, create: false) else {
            revision = .absent
            return SubscriptionCatalog()
        }
        return try folder.withLock {
            guard let record = try folder.read(Self.file) else {
                revision = .absent
                return SubscriptionCatalog()
            }
            if record.starts(with: Self.magic) {
                let catalog = try Self.decode(decrypt(record))
                revision = Revision(record)
                return catalog
            }

            // Decode first. If the old file is unreadable or the replacement
            // cannot be written, keep the original bytes available for recovery.
            let catalog = try Self.decode(record)
            let encrypted = try seal(catalog, key: keyStore.createIfAbsent())
            try folder.publish(encrypted, as: Self.file, replace: true)
            revision = Revision(encrypted)
            return catalog
        }
    }

    func save(_ catalog: SubscriptionCatalog) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard let folder = try PrivateSubscriptionFiles(directory, create: true) else { throw SubscriptionStorageError.fileAccess }
        try folder.withLock {
            let existing = try folder.read(Self.file)
            guard revision == Revision(existing) else { throw SubscriptionStorageError.catalogChanged }
            let key: Data
            if let existing {
                key = try existingKey()
                // A replaced/missing key never becomes the key for a new
                // snapshot until it proves it can decrypt the current one.
                _ = try decrypt(existing, using: key)
            } else { key = try keyStore.createIfAbsent() }
            let encrypted = try seal(catalog, key: key)
            try folder.publish(encrypted, as: Self.file, replace: existing != nil)
            revision = Revision(encrypted)
        }
    }

    private func existingKey() throws -> Data {
        guard let key = try keyStore.load() else { throw SubscriptionStorageError.keyMissing }
        return key
    }

    private func decrypt(_ record: Data, using suppliedKey: Data? = nil) throws -> Data {
        guard record.starts(with: Self.header) else { throw SubscriptionStorageError.unsupportedFormat }
        let key = try suppliedKey ?? existingKey()
        guard key.count == 32 else { throw SubscriptionStorageError.invalidKey }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(record.dropFirst(Self.header.count)))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Self.header)
        } catch { throw SubscriptionStorageError.unreadableCatalog }
    }

    private func seal(_ catalog: SubscriptionCatalog, key: Data) throws -> Data {
        guard key.count == 32 else { throw SubscriptionStorageError.invalidKey }
        do {
            let json = try JSONEncoder().encode(catalog)
            let box = try AES.GCM.seal(json, using: SymmetricKey(data: key), authenticating: Self.header)
            guard let combined = box.combined else { throw SubscriptionStorageError.fileAccess }
            return Self.header + combined
        } catch { throw SubscriptionStorageError.fileAccess }
    }

    private static func decode(_ data: Data) throws -> SubscriptionCatalog {
        do { return try JSONDecoder().decode(SubscriptionCatalog.self, from: data) }
        catch { throw SubscriptionStorageError.unreadableCatalog }
    }
}

enum SubscriptionStorageError: LocalizedError, Equatable {
    case fileAccess, keyMissing, invalidKey, unreadableCatalog, unsupportedFormat, catalogChanged

    var errorDescription: String? {
        switch self {
        case .fileAccess: return "无法读写本地订阅文件。请检查存储权限。"
        case .keyMissing: return "本机订阅密钥已缺失。请从原备份恢复密钥和订阅文件。"
        case .invalidKey: return "本机订阅密钥不可用。请检查密钥文件或从原备份恢复。"
        case .unreadableCatalog: return "订阅文件无法解密或内容损坏。原文件已保留。"
        case .unsupportedFormat: return "此版本无法读取本机订阅文件的格式。原文件已保留。"
        case .catalogChanged: return "磁盘上的订阅已变更或尚未成功读取。请重启 CLAY 重新载入。"
        }
    }
}

protocol SubscriptionKeyStore {
    func load() throws -> Data?
    func createIfAbsent() throws -> Data
}

/// Ad hoc app builds lack a stable Keychain signing identity across upgrades.
/// The per-user key lives outside the catalog with restrictive permissions.
/// This protects a separate catalog copy, not full account access or backups.
struct LocalSubscriptionKeyStore: SubscriptionKeyStore {
    private static let file = "subscriptions.key"
    let directory: URL

    func load() throws -> Data? {
        do {
            guard let folder = try PrivateSubscriptionFiles(directory, create: false) else { return nil }
            return try folder.read(Self.file, key: true)
        } catch { throw SubscriptionStorageError.invalidKey }
    }

    func createIfAbsent() throws -> Data {
        do {
            let parentURL = directory.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw SubscriptionStorageError.invalidKey }
            defer { close(parent) }
            guard let folder = try PrivateSubscriptionFiles(directory, create: true) else { throw SubscriptionStorageError.invalidKey }
            let key: Data
            if let existing = try folder.read(Self.file, key: true) {
                key = existing
            } else {
                let candidate = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                // Exclusive publication means simultaneous first launches
                // can never replace a key that another launch already used.
                if try folder.publish(candidate, as: Self.file, replace: false, acceptExisting: true) {
                    key = candidate
                } else {
                    guard let existing = try folder.read(Self.file, key: true) else { throw SubscriptionStorageError.invalidKey }
                    key = existing
                }
            }
            // Persist the new key entry before publishing any catalog that
            // needs it, including after an earlier interrupted first save.
            try folder.synchronizeDirectory()
            try PrivateSubscriptionFiles.synchronize(parent)
            return key
        } catch { throw SubscriptionStorageError.invalidKey }
    }
}

/// File descriptors anchor all operations to a verified private directory. New
/// files are restrictive from creation and only become visible after rename.
private final class PrivateSubscriptionFiles {
    private let descriptor: Int32

    init?(_ url: URL, create: Bool) throws {
        if create {
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw SubscriptionStorageError.fileAccess }
        }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if !create, errno == ENOENT { return nil }
            throw SubscriptionStorageError.fileAccess
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & 0o7777 == 0o700 || fchmod(fd, 0o700) == 0) else {
            close(fd)
            throw SubscriptionStorageError.fileAccess
        }
        descriptor = fd
    }

    deinit { close(descriptor) }

    func synchronizeDirectory() throws {
        try Self.synchronize(descriptor)
    }

    static func synchronize(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            if errno != EINTR { throw SubscriptionStorageError.fileAccess }
        }
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = openat(descriptor, ".catalog.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw SubscriptionStorageError.fileAccess }
        defer { close(fd) }
        let attributes = try info(fd)
        guard attributes.st_mode & 0o7777 == 0o600 || fchmod(fd, 0o600) == 0 else { throw SubscriptionStorageError.fileAccess }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw SubscriptionStorageError.fileAccess }
        }
        return try body()
    }

    func read(_ name: String, key: Bool = false) throws -> Data? {
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw SubscriptionStorageError.fileAccess
        }
        defer { close(fd) }
        let attributes = try info(fd)
        if key, attributes.st_mode & 0o7777 != 0o600 || attributes.st_size != 32 {
            throw SubscriptionStorageError.invalidKey
        }
        do { return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data() }
        catch { throw SubscriptionStorageError.fileAccess }
    }

    @discardableResult
    func publish(_ data: Data, as name: String, replace: Bool, acceptExisting: Bool = false) throws -> Bool {
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SubscriptionStorageError.fileAccess }
        defer { close(fd); _ = unlinkat(descriptor, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw SubscriptionStorageError.fileAccess }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch { throw SubscriptionStorageError.fileAccess }
        let result = replace ? renameat(descriptor, temporary, descriptor, name)
                             : renameatx_np(descriptor, temporary, descriptor, name, UInt32(RENAME_EXCL))
        if result != 0, errno == EEXIST, acceptExisting { return false }
        guard result == 0 else { throw SubscriptionStorageError.fileAccess }
        return true
    }

    private func info(_ fd: Int32) throws -> stat {
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
              details.st_uid == geteuid(), details.st_nlink == 1 else { throw SubscriptionStorageError.fileAccess }
        return details
    }
}
