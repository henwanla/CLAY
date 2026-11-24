import Foundation

/// One connection currently owned by the local Mihomo session. Fields are
/// meant for the live dashboard and are never written to a report or history.
public struct ProxyConnection: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let host: String
    public let destinationIP: String
    public let destinationPort: Int?
    public let network: String
    public let type: String
    public let chains: [String]
    public let rule: String
    public let rulePayload: String
    public let upload: Int64
    public let download: Int64
    public let start: Date?
}

/// Counts traffic processed by this Mihomo session, not traffic that bypasses
/// the proxy in a client (including PAC DIRECT requests).
public struct ProxyTelemetry: Equatable, Sendable {
    public let sampledAt: Date
    public let uploadTotal: Int64
    public let downloadTotal: Int64
    /// Bytes per second since the previous successful sample. Nil for the
    /// first sample, a counter reset, or samples taken too close together.
    public let uploadRate: Int64?
    public let downloadRate: Int64?
    public let connections: [ProxyConnection]
    /// Full active count before limiting the details to the 1000 newest rows.
    public let connectionCount: Int
}

struct MihomoSnapshot: Decodable {
    let uploadTotal: Int64
    let downloadTotal: Int64
    let connections: [Row]?

    struct Row: Decodable {
        let id: UUID
        let metadata: Metadata
        let chains: [String]?
        let rule: String
        let rulePayload: String
        let upload: Int64
        let download: Int64
        let start: String

        struct Metadata: Decodable {
            let host: String
            let destinationIP: String
            let destinationPort: String
            let network: String
            let type: String
        }

        func view() -> ProxyConnection {
            let timestamp = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(start))
                ?? (try? Date.ISO8601FormatStyle().parse(start))
            return ProxyConnection(id: id, host: metadata.host, destinationIP: metadata.destinationIP,
                                   destinationPort: Int(metadata.destinationPort).flatMap { (1...65535).contains($0) ? $0 : nil },
                                   network: metadata.network, type: metadata.type, chains: chains ?? [], rule: rule,
                                   rulePayload: rulePayload, upload: max(0, upload), download: max(0, download), start: timestamp)
        }
    }
}

/// Use the same process totals shown by GET /connections. Measuring the
/// difference with a monotonic clock accounts for delayed UI polling.
struct TrafficMeter {
    private var previous: (instant: ContinuousClock.Instant, upload: Int64, download: Int64)?

    mutating func sample(_ value: MihomoSnapshot, at instant: ContinuousClock.Instant, date: Date) -> ProxyTelemetry {
        let upload = max(0, value.uploadTotal), download = max(0, value.downloadTotal)
        var uploadRate: Int64?, downloadRate: Int64?
        if let previous {
            let elapsed = previous.instant.duration(to: instant).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            if seconds >= 0.1 {
                uploadRate = Self.rate(now: upload, then: previous.upload, seconds: seconds)
                downloadRate = Self.rate(now: download, then: previous.download, seconds: seconds)
                self.previous = (instant, upload, download)
            }
        } else { previous = (instant, upload, download) }

        let rows = value.connections ?? []
        let ordered = rows.map { $0.view() }.sorted { a, b in
            if a.start == b.start { return a.id.uuidString < b.id.uuidString }
            return (a.start ?? .distantPast) > (b.start ?? .distantPast)
        }
        return ProxyTelemetry(sampledAt: date, uploadTotal: upload, downloadTotal: download,
                              uploadRate: uploadRate, downloadRate: downloadRate,
                              connections: Array(ordered.prefix(1000)), connectionCount: rows.count)
    }

    private static func rate(now: Int64, then: Int64, seconds: Double) -> Int64? {
        guard now >= then else { return nil }
        let rate = floor(Double(now - then) / seconds)
        return rate >= Double(Int64.max) ? Int64.max : Int64(rate)
    }
}
