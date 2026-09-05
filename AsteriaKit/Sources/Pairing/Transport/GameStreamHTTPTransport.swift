import Foundation
import Security
import CryptoKit

/// Real transport with HTTP and HTTPS mutual-TLS (client cert + server public-key pinning).
///
/// The HTTPS path drives `/usr/bin/curl` with the client identity supplied as raw PEM. This is a
/// deliberate workaround for macOS 27, where the native TLS stacks cannot complete client-certificate
/// authentication with an identity resolved from the classic file-based keychain:
///   - URLSession returns NSURLError -1200 ("A TLS error caused the secure connection to fail")
///   - Network.framework fails the handshake (-9858)
///   - the in-memory constructors are broken too: `SecKeyCreateWithData` returns errSecParam for a
///     valid PKCS#1 RSA key, and there is no `sec_identity_create_with_certificates` in this SDK.
/// The same certificate+key presented as raw PEM works (verified against a live Sunshine host).
/// Server trust is pinned via curl's `--pinnedpubkey` (SHA-256 of the pinned certificate's
/// SubjectPublicKeyInfo), so the MITM protection matches the previous full-certificate pin.
public final class GameStreamHTTPTransport: GameStreamTransport, @unchecked Sendable {
    public let host: String
    public let httpPort: UInt16
    public let httpsPort: UInt16
    public let requestTimeout: TimeInterval

    private let clientPEM: String
    private let curlExecutable: URL
    private let lock = NSLock()
    private var pinnedServerCertDER: Data?
    private var pinnedPublicKeyHash: String?
    private var clientPEMFileURL: URL?

    public convenience init(
        host: String,
        identity: ClientIdentity,
        httpPort: UInt16 = 47989,
        httpsPort: UInt16 = 47984,
        requestTimeout: TimeInterval = 310
    ) {
        self.init(
            host: host, identity: identity, httpPort: httpPort, httpsPort: httpsPort,
            requestTimeout: requestTimeout, curlExecutable: URL(fileURLWithPath: "/usr/bin/curl"))
    }

    init(
        host: String,
        identity: ClientIdentity,
        httpPort: UInt16 = 47989,
        httpsPort: UInt16 = 47984,
        requestTimeout: TimeInterval = 310,
        curlExecutable: URL
    ) {
        self.host = host
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.requestTimeout = requestTimeout
        self.clientPEM = identity.combinedPEM
        self.curlExecutable = curlExecutable
    }

    deinit {
        let url = lock.withLock { clientPEMFileURL }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    public func setPinnedServerCertificate(_ der: [UInt8]?) {
        lock.withLock {
            pinnedServerCertDER = der.map { Data($0) }
            pinnedPublicKeyHash = der.flatMap { Self.publicKeyPinHash(for: Data($0)) }
        }
    }

    public func get(secure: Bool, path: String, query: [URLQueryItem]) async throws -> Data {
        let url = try makeURL(secure: secure, path: path, query: query)
        return try await perform(url: url, method: "GET", body: nil, path: path, query: query)
    }

    public func post(secure: Bool, path: String, query: [URLQueryItem], body: Data) async throws -> Data {
        let url = try makeURL(secure: secure, path: path, query: query)
        return try await perform(url: url, method: "POST", body: body, path: path, query: query)
    }

    /// The full-certificate pin equality predicate, retained for reference and tests. The curl path
    /// pins the server's public key instead of the full certificate.
    static func serverCertificateMatchesPin(presented: Data?, pinned: Data?) -> Bool {
        guard let presented, let pinned else { return false }
        return presented == pinned
    }

    /// SHA-256 (base64) of the pinned certificate's SubjectPublicKeyInfo — exactly what curl's
    /// `--pinnedpubkey` hashes on macOS (verified against a live host: a mismatched pin makes curl
    /// exit 90).
    static func publicKeyPinHash(for certificateDER: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let key = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else { return nil }
        let spki = spkiWrappingRSA(pkcs1)
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    /// Wrap a PKCS#1 RSAPublicKey in the SubjectPublicKeyInfo structure curl hashes:
    /// `SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { pkcs1 } }`.
    private static func spkiWrappingRSA(_ pkcs1: Data) -> Data {
        let algorithm = Data([
            0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d,
            0x01, 0x01, 0x01, 0x05, 0x00,
        ])
        let bitString = Data([0x03]) + derLength(1 + pkcs1.count) + Data([0x00]) + pkcs1
        return Data([0x30]) + derLength(algorithm.count + bitString.count) + algorithm + bitString
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes = [UInt8]()
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
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

    private func perform(
        url: URL, method: String, body: Data?, path: String, query: [URLQueryItem]
    ) async throws -> Data {
        let urlIsSecure = url.scheme == "https"
        let (pinHash, isPinned) = lock.withLock { (pinnedPublicKeyHash, pinnedServerCertDER != nil) }
        // A secure request before a pin was captured fails closed, matching the previous transport.
        guard !urlIsSecure || (isPinned && pinHash != nil) else {
            throw PairingError.serverVerificationFailed
        }

        let clientPEMURL: URL
        do {
            clientPEMURL = try ensureClientPEMFile()
        } catch {
            throw PairingError.transport("couldn't stage the client TLS identity: \(error.localizedDescription)")
        }

        let workDir = FileManager.default.temporaryDirectory
        let bodyFile = workDir.appendingPathComponent("asteria-body-\(UUID().uuidString)")
        let outputFile = workDir.appendingPathComponent("asteria-out-\(UUID().uuidString)")
        let statusFile = workDir.appendingPathComponent("asteria-status-\(UUID().uuidString)")
        let errorFile = workDir.appendingPathComponent("asteria-error-\(UUID().uuidString)")
        defer {
            for file in [bodyFile, outputFile, statusFile, errorFile] {
                try? FileManager.default.removeItem(at: file)
            }
        }

        var arguments = [
            "-sS",                                   // silent; surface errors on stderr
            "-o", outputFile.path,                   // response body -> file
            "-w", "%{http_code}",                    // HTTP status -> stdout
            "--connect-timeout", "10",
            "--max-time", String(Int(requestTimeout)),
        ]
        if urlIsSecure {
            arguments += [
                "-k",                                // host cert is self-signed; trust via the pin below
                "--pinnedpubkey", "sha256//\(pinHash!)",
                "--cert", clientPEMURL.path,
                "--key", clientPEMURL.path,
            ]
        }
        if method == "POST" {
            if let body { try body.write(to: bodyFile) }
            arguments += ["--data-binary", "@\(bodyFile.path)"]
        }
        arguments.append(url.absoluteString)

        try Data().write(to: statusFile)
        try Data().write(to: errorFile)
        let statusHandle = try FileHandle(forWritingTo: statusFile)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer {
            try? statusHandle.close()
            try? errorHandle.close()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = curlExecutable
            process.arguments = arguments
            process.standardOutput = statusHandle
            process.standardError = errorHandle
            process.terminationHandler = { proc in
                let status = (try? String(contentsOf: statusFile, encoding: .utf8)) ?? ""
                let detail = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
                continuation.resume(with: Self.classify(
                    exitCode: proc.terminationStatus, statusText: status, detail: detail,
                    outputFile: outputFile, path: path, query: query))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: PairingError.transport(
                    "curl failed to start: \(error.localizedDescription)"))
            }
        }
    }

    /// Stage the client certificate + private key PEM for curl, owner-only (0600), once per transport.
    private func ensureClientPEMFile() throws -> URL {
        try lock.withLock {
            if let existing = clientPEMFileURL { return existing }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("asteria-client-\(UUID().uuidString).pem")
            try Data(clientPEM.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            clientPEMFileURL = url
            return url
        }
    }

    private static func classify(
        exitCode: Int32, statusText: String, detail: String,
        outputFile: URL, path: String, query: [URLQueryItem]
    ) -> Result<Data, Error> {
        if exitCode != 0 {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            switch exitCode {
            case 90, 35, 51, 56, 60:   // pin mismatch / TLS / peer-certificate failures
                return .failure(PairingError.serverVerificationFailed)
            case 28:
                return .failure(PairingError.transport("request timed out"))
            case 6, 7:
                return .failure(PairingError.transport("couldn't reach the PC: \(trimmed)"))
            default:
                return .failure(PairingError.transport("curl exit \(exitCode): \(trimmed)"))
            }
        }
        if let code = Int(statusText.trimmingCharacters(in: .whitespacesAndNewlines)),
           !(200...299).contains(code) {
            return .failure(PairingError.httpStatus(code))
        }
        let data = (try? Data(contentsOf: outputFile)) ?? Data()
        captureIfEnabled(data, path: path, query: query)
        return .success(data)
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
}