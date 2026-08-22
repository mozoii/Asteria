import Foundation

/// Abstracts host HTTP/HTTPS for testability against a simulated server.
public protocol GameStreamTransport: Sendable {
    func get(secure: Bool, path: String, query: [URLQueryItem]) async throws -> Data

    /// POST with a raw request body; used by Apollo's clipboard endpoint.
    func post(secure: Bool, path: String, query: [URLQueryItem], body: Data) async throws -> Data

    /// Pin the host's certificate (DER) for TLS server-trust validation (test transports can ignore).
    func setPinnedServerCertificate(_ der: [UInt8]?)
}

public extension GameStreamTransport {
    func setPinnedServerCertificate(_ der: [UInt8]?) {}

    /// Transports that only serve GET (test doubles, unpaired stages) don't implement POST.
    func post(secure: Bool, path: String, query: [URLQueryItem], body: Data) async throws -> Data {
        throw PairingError.notImplemented("POST")
    }
}
