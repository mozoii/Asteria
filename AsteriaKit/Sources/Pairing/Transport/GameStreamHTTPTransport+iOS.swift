#if os(iOS)
import Foundation
import Security

/// Real transport with HTTP and HTTPS mutual-TLS (client cert + full-certificate server pinning).
///
/// iOS has no `Process`, so the macOS curl workaround cannot be used here. It is also not needed: the
/// curl path exists only because macOS 27's *classic file-based* keychain cannot complete a client-
/// certificate handshake (see the macOS file's header), and iOS stores the identity in the
/// data-protection keychain instead. This is the transport Asteria shipped before that workaround, with
/// the trust decision lifted into `ServerCertificatePin` so both platforms pin by the same rule.
///
/// The client identity is resolved through `ClientIdentity.makeTLSIdentity()`, the same keychain lookup
/// the app uses everywhere else. If a device ever fails that lookup, this initializer is the single
/// place to swap in another resolution strategy; nothing else in the stack sees a `SecIdentity`.
public final class GameStreamHTTPTransport: NSObject, GameStreamTransport, URLSessionDelegate, @unchecked Sendable {
    public let host: String
    public let httpPort: UInt16
    public let httpsPort: UInt16
    public let requestTimeout: TimeInterval

    private let tlsIdentity: TLSClientIdentity
    private let lock = NSLock()
    private var pinnedServerCertDER: Data?
    /// Sessions whose trust challenge we refused, so the resulting URLError can be reported as a pin
    /// failure rather than a generic transport error.
    private var rejectedSessions: Set<ObjectIdentifier> = []

    public init(
        host: String,
        identity: ClientIdentity,
        httpPort: UInt16 = 47989,
        httpsPort: UInt16 = 47984,
        requestTimeout: TimeInterval = 310
    ) throws {
        self.host = host
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.requestTimeout = requestTimeout
        self.tlsIdentity = try identity.makeTLSIdentity()
        super.init()
    }

    public func setPinnedServerCertificate(_ der: [UInt8]?) {
        lock.withLock { pinnedServerCertDER = der.map { Data($0) } }
    }

    private var pinned: Data? { lock.withLock { pinnedServerCertDER } }

    public func get(secure: Bool, path: String, query: [URLQueryItem]) async throws -> Data {
        let request = URLRequest(url: try makeURL(secure: secure, path: path, query: query))
        return try await send(request, path: path, query: query)
    }

    public func post(secure: Bool, path: String, query: [URLQueryItem], body: Data) async throws -> Data {
        var request = URLRequest(url: try makeURL(secure: secure, path: path, query: query))
        request.httpMethod = "POST"
        request.httpBody = body
        return try await send(request, path: path, query: query)
    }

    private func makeURL(secure: Bool, path: String, query: [URLQueryItem]) throws -> URL {
        try GameStreamURL.make(host: host, secure: secure, httpPort: httpPort,
                               httpsPort: httpsPort, path: path, query: query)
    }

    private func send(_ request: URLRequest, path: String, query: [URLQueryItem]) async throws -> Data {
        // A secure request before a pin was captured fails closed before any bytes reach the network,
        // matching the macOS transport rather than relying on the trust callback to refuse it.
        if request.url?.scheme == "https", pinned == nil {
            throw PairingError.serverVerificationFailed
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
            clearRejection(for: session)
        }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            if consumeRejection(for: session) { throw PairingError.serverVerificationFailed }
            throw PairingError.transport(Self.message(for: error))
        }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PairingError.httpStatus(http.statusCode)
        }
        TransportCapture.captureIfEnabled(data, path: path, query: query)
        return data
    }

    /// Mirror the macOS transport's error wording so the user-facing text doesn't change by platform.
    static func message(for error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .timedOut: return "request timed out"
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return "couldn't reach the PC: \(urlError.localizedDescription)"
        default: return urlError.localizedDescription
        }
    }

    private func recordRejection(for session: URLSession) {
        lock.withLock { _ = rejectedSessions.insert(ObjectIdentifier(session)) }
    }

    private func consumeRejection(for session: URLSession) -> Bool {
        lock.withLock { rejectedSessions.remove(ObjectIdentifier(session)) != nil }
    }

    private func clearRejection(for session: URLSession) {
        lock.withLock { _ = rejectedSessions.remove(ObjectIdentifier(session)) }
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(.useCredential, URLCredential(identity: tlsIdentity.secIdentity,
                                                            certificates: nil, persistence: .forSession))

        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
            let leaf = chain?.first.map { SecCertificateCopyData($0) as Data }
            // The host certificate is self-signed, so system trust evaluation is meaningless here; the
            // pin captured during pairing is the whole of the MITM protection and it fails closed.
            switch ServerCertificatePin.decide(presentedLeaf: leaf, pinned: pinned) {
            case .accept:
                completionHandler(.useCredential, URLCredential(trust: trust))
            case .rejectUnpinned, .rejectMismatch:
                recordRejection(for: session)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
#endif
