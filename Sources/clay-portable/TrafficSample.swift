import Foundation

/// The first /traffic record contains counters only, unlike /connections.
struct TrafficSample: Decodable {
    let upTotal: Int64
    let downTotal: Int64

    static func reply(_ data: Data) -> String {
        guard let value = try? JSONDecoder().decode(Self.self, from: data),
              value.upTotal >= 0, value.downTotal >= 0 else { return "traffic=unavailable" }
        return "traffic=up:\(value.upTotal) down:\(value.downTotal)"
    }
}
