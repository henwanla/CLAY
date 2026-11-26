#if CLAY_DOCUMENTATION
import AppKit
@testable @_spi(Checks) import CLAYCore
import SwiftUI

private final class DocumentationPACBackend: SystemPACBackend {
    func effectivePACURLs() -> Set<String> { [] }
    func withLocked<T>(interactive: Bool, _ body: (any SystemPACSession) throws -> T) throws -> T {
        throw CocoaError(.featureUnsupported)
    }
}

@main struct DocumentationSnapshots {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileWriteInvalidFileName) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "CLAYDocumentation-\(UUID())"
        guard let preferences = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache)
        }
        let manager = SystemPACManager(backend: DocumentationPACBackend(), journalDirectory: cache.appendingPathComponent("pac"))
        let store = SubscriptionStore(directory: cache.appendingPathComponent("subscriptions"),
                                      keyStore: LocalSubscriptionKeyStore(directory: cache.appendingPathComponent("private")))
        let model = Workspace(store: store, pac: PACControl(manager: manager, preferences: preferences), preferences: preferences)
        let sample = "vless://4624a73a-98ce-43e7-8868-4deba224779c@node.example.test:443#示例节点"
        guard model.applyImport(sample), let node = model.chosen else { throw CocoaError(.fileReadCorruptFile) }
        model.selectRoutingMode(.rule)

        let now = Date(timeIntervalSince1970: 1_764_118_800)
        let rows = ["docs.example.test", "cdn.example.test", "api.example.test", "images.example.test", "updates.example.test"]
            .enumerated().map { index, host in
                ProxyConnection(id: UUID(), host: host, destinationIP: "192.0.2.\(10 + index)", destinationPort: 443,
                                network: "tcp", type: "HTTPS", chains: ["CLAY", node.localName], rule: "DomainSuffix",
                                rulePayload: "example.test", upload: Int64((6 + index * 5) * 1024),
                                download: Int64((96 + index * 179) * 1024), start: now.addingTimeInterval(Double(-index * 14)))
            }
        let uploads = [50, 42, 70, 86, 78, 105, 87, 126, 143, 99, 113, 96]
        let downloads = [165, 285, 240, 492, 380, 710, 815, 610, 1120, 895, 1360, 1240]
        let points = uploads.indices.map { index in
            TrafficPoint(time: now.addingTimeInterval(Double(index - uploads.count + 1) * 3),
                         upload: Int64(uploads[index] * 1024), download: Int64(downloads[index] * 1024), segment: 0)
        }
        let snapshot = ProxyTelemetry(sampledAt: now, uploadTotal: 1_474_560, downloadTotal: 24_379_392,
                                      uploadRate: points.last?.upload, downloadRate: points.last?.download,
                                      connections: rows, connectionCount: rows.count)
        model.showDocumentationTraffic(snapshot, points: points)
        model.pac.showDocumentationSystemProxy()

        // Render standalone views. No screen capture, window, app interaction,
        // engine process, network access or user's workspace storage is needed.
        NSApplication.shared.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try render(model: model, connections: false, to: output.appendingPathComponent("macos-overview.png"))
        try render(model: model, connections: true, to: output.appendingPathComponent("macos-connections.png"))
    }

    @MainActor private static func render(model: Workspace, connections: Bool, to file: URL) throws {
        let size = CGSize(width: 940, height: connections ? 540 : 800)
        let content = documentationDashboard(model: model, connections: connections)
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: file, options: .atomic)
    }
}
#endif
