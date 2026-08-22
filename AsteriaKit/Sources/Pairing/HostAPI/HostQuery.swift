import Foundation

/// Builds GameStream host request queries (adds `uniqueid` + random `uuid`).
enum HostQuery {
    static let clientName = "Asteria"

    static func base(uniqueId: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "uniqueid", value: uniqueId),
            URLQueryItem(name: "uuid", value: Hex.encode(PairingRandom.bytes(8))),
        ]
    }

    static func base(uniqueId: String, _ extra: [URLQueryItem]) -> [URLQueryItem] {
        base(uniqueId: uniqueId) + extra
    }

    static func base(uniqueId: String, _ extra: [(String, String)]) -> [URLQueryItem] {
        base(uniqueId: uniqueId) + extra.map { URLQueryItem(name: $0.0, value: $0.1) }
    }
}
