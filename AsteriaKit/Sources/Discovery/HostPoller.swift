import Foundation

/// Fetches and parses `/serverinfo` from a host over plain HTTP (works unpaired).
public enum HostPoller {
    public static func fetchServerInfo(
        host: String,
        httpPort: UInt16 = 47989,
        timeout: TimeInterval = 8
    ) async throws -> ServerInfo {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = Int(httpPort)
        comps.path = "/serverinfo"
        guard let url = comps.url else { throw ServerInfoParseError.malformed("invalid host \(host)") }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        let (data, _) = try await URLSession(configuration: config).data(from: url)
        return try ServerInfoParser.parse(data)
    }
}
