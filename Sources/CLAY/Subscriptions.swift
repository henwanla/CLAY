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
struct SubscriptionStore {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("subscriptions.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory
            .appendingPathComponent("CLAY", isDirectory: true)
            .appendingPathComponent("Subscriptions", isDirectory: true)
    }

    func load() throws -> SubscriptionCatalog {
        do { return try JSONDecoder().decode(SubscriptionCatalog.self, from: Data(contentsOf: file)) }
        catch CocoaError.fileReadNoSuchFile { return SubscriptionCatalog() }
    }

    func save(_ catalog: SubscriptionCatalog) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(catalog)
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Both paths are in the same directory. rename publishes the completed
        // snapshot atomically and leaves the previous one intact on failure.
        guard rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
