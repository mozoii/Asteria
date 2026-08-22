import Foundation
import Security

/// Real transport with HTTP and HTTPS mutual-TLS (client cert + server cert pinning).
public final class GameStreamHTTPTransport: NSObject, GameStreamTransport, URLSessionDelegate, @unchecked Sendable {
    public let host: String
    public let httpPort: UInt16
    public let httpsPort: UInt16
    public let requestTimeout: TimeInterval

    private let tlsIdentity: TLSClientIdentity
    private var secIdentity: SecIdentity { tlsIdentity.secIdentity }
    private let lock = NSLock()
    private var _pinnedServerCertDER: Data?
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
        lock.lock(); _pinnedServerCertDER = der.map { Data($0) }; lock.unlock()
    }
    private var pinnedServerCertDER: Data? {
        lock.lock(); defer { lock.unlock() }; return _pinnedServerCertDER
    }

    static func serverCertificateMatchesPin(presented: Data?, pinned: Data?) -> Bool {
        guard let presented, let pinned else { return false }
        return presented == pinned
    }

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
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.host = host
        components.port = Int(secure ? httpsPort : httpPort)
        components.path = "/" + path
        components.queryItems = query
        guard let url = components.url else { throw PairingError.transport("invalid URL") }
        return url
    }

    private func send(_ request: URLRequest, path: String, query: [URLQueryItem]) async throws -> Data {
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
            if consumeRejection(for: session) {
                throw PairingError.serverVerificationFailed
            }
            throw error
        }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PairingError.httpStatus(http.statusCode)
        }
        Self.captureIfEnabled(data, path: path, query: query)
        return data
    }

    private func recordRejection(for session: URLSession) {
        lock.lock()
        rejectedSessions.insert(ObjectIdentifier(session))
        lock.unlock()
    }

    private func consumeRejection(for session: URLSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedSessions.remove(ObjectIdentifier(session)) != nil
    }

    private func clearRejection(for session: URLSession) {
        lock.lock()
        rejectedSessions.remove(ObjectIdentifier(session))
        lock.unlock()
    }

#if DEBUG
    private static func captureIfEnabled(_ data: Data, path: String, query: [URLQueryItem]) {
        guard let dir = ProcessInfo.processInfo.environment["ASTERIA_CAPTURE_DIR"] else { return }
        let phrase = query.first { $0.name == "phrase" }?.value
        let name = phrase.map { "\(path)-\($0)" } ?? path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).xml"))
    }
#else
    private static func captureIfEnabled(_ data: Data, path: String, query: [URLQueryItem]) {}
#endif

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(.useCredential, URLCredential(identity: secIdentity, certificates: nil, persistence: .forSession))

        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil); return
            }
            // Fail closed: trust only the pinned cert, never accept MITM.
            guard let pin = pinnedServerCertDER else {
                recordRejection(for: session)
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
            let leafData = chain?.first.map { SecCertificateCopyData($0) as Data }
            if Self.serverCertificateMatchesPin(presented: leafData, pinned: pin) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                recordRejection(for: session)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
