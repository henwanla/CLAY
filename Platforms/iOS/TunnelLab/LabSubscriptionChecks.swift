import CLAYCore
import CryptoKit
import Foundation

private enum Failure: Error { case assertion(String), fixture }

private struct FixtureKey: LabSubscriptionKey {
    let value: Data?
    func load() -> SymmetricKey? { value.map { SymmetricKey(data: $0) } }
    func createIfAbsent() throws -> SymmetricKey { throw Failure.fixture }
}

private actor Upstream {
    private var failNext = false
    private var holdNext = false
    private var held: CheckedContinuation<String, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    var label = "first-fixture"

    func respond(_ url: URL) async throws -> LabSubscriptionStore.Download {
        guard url.host == "example.invalid" else { throw Failure.fixture }
        if failNext { failNext = false; throw Failure.fixture }
        let name: String
        if holdNext {
            holdNext = false
            name = await withCheckedContinuation { request in
                held = request
                observer?.resume()
                observer = nil
            }
        } else { name = label }
        let content = "vless://4624a73a-98ce-43e7-8868-4deba224779c@192.0.2.50:443#" + name
        return try LabSubscriptionStore.Download(content: content, count: SubscriptionImporter.parse(content).profiles.count)
    }

    func setLabel(_ value: String) { label = value }
    func rejectNext() { failNext = true }
    func stallNext() { holdNext = true }
    func waitUntilHeld() async {
        if held == nil { await withCheckedContinuation { observer = $0 } }
    }
    func finishHeld() {
        held?.resume(returning: "late-fixture")
        held = nil
    }
}

@main private struct LabSubscriptionChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = Upstream()
        let fixtureKey = FixtureKey(value: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        func store(_ key: FixtureKey) -> LabSubscriptionStore {
            LabSubscriptionStore(directory: directory, key: key, fetch: { try await upstream.respond($0) })
        }
        let first = store(fixtureKey)
        let address = "https://example.invalid/file?auth=synthetic-secret"
        for invalid in ["http://localhost:80/profile", "https://user:secret@example.invalid/profile", "https://example.invalid/#fragment"] {
            try require((try? LabSubscriptionStore.https(invalid)) == nil, "reject insecure or malformed addresses")
        }

        try await first.add(name: "Private label", address: address)
        let entries = try await first.summaries()
        try require(entries.count == 1, "one saved record")
        let id = entries[0].id
        let location = directory.appendingPathComponent(id.uuidString + ".claysub")
        let ciphertext = try Data(contentsOf: location)
        for secret in ["Private label", "synthetic-secret", "192.0.2.50", "first-fixture"] {
            try require(ciphertext.range(of: Data(secret.utf8)) == nil, "secret must not appear in clear text")
        }

        let reopened = store(fixtureKey)
        var name = SubscriptionImporter.parse(try await reopened.load(id)).profiles.first?.name
        try require(name == "first-fixture", "reopen decrypts the saved nodes")
        await upstream.rejectNext()
        try await rejects { try await reopened.refresh(id) }
        try require(try Data(contentsOf: location) == ciphertext, "failed refresh preserves original bytes")

        await upstream.stallNext()
        let previous = Task { try await reopened.refresh(id) }
        await upstream.waitUntilHeld()
        await upstream.setLabel("fresh-fixture")
        try await reopened.refresh(id)
        await upstream.finishHeld()
        try await rejects { try await previous.value }
        name = SubscriptionImporter.parse(try await reopened.load(id)).profiles.first?.name
        try require(name == "fresh-fixture", "late refresh cannot overwrite a newer result")

        let freshCiphertext = try Data(contentsOf: location)
        var damaged = freshCiphertext
        damaged[damaged.index(before: damaged.endIndex)] ^= 1
        try damaged.write(to: location, options: .atomic)
        try await rejects { _ = try await reopened.load(id) }
        try freshCiphertext.write(to: location, options: .atomic)

        let replacedID = UUID()
        try freshCiphertext.write(to: directory.appendingPathComponent(replacedID.uuidString + ".claysub"))
        let changed = try await reopened.summaries()
        try require(changed.contains { $0.id == replacedID && $0.count == nil }, "ciphertext bound to the record UUID")
        try await reopened.remove(replacedID)
        try await rejects { try await store(FixtureKey(value: nil)).add(name: "", address: address) }
        try require(try Data(contentsOf: location) == freshCiphertext, "missing key does not replace existing cache")

        await upstream.stallNext()
        let pending = Task { try await reopened.refresh(id) }
        await upstream.waitUntilHeld()
        try await reopened.remove(id)
        await upstream.finishHeld()
        try await rejects { try await pending.value }
        let empty = try await reopened.summaries()
        try require(empty.isEmpty, "in-flight refresh cannot recreate a deleted record")
        print("PASS iOS subscription HTTPS validation, authenticated cache, refresh ordering and deletion")
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.assertion(message) }
    }

    static func rejects(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw Failure.assertion("expected a failed operation")
    }
}
