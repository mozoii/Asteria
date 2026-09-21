import Foundation
import Security
import CryptoKit

/// What to do with a server-trust challenge, decided from the presented leaf and the pinned certificate
/// alone so the policy is testable without a live host. Pinning fails closed: anything other than an
/// exact match of a certificate captured during pairing is refused, including the unpinned case.
public enum ServerTrustDecision: Equatable, Sendable {
    case accept
    /// No pin captured yet — a secure request this early can only be answered by trusting a stranger.
    case rejectUnpinned
    case rejectMismatch
}

/// The server-certificate pin shared by both transports: macOS hands the public-key hash to curl's
/// `--pinnedpubkey`, iOS compares the full leaf in a `URLSession` trust challenge.
public enum ServerCertificatePin {
    public static func decide(presentedLeaf: Data?, pinned: Data?) -> ServerTrustDecision {
        guard pinned != nil else { return .rejectUnpinned }
        return matches(presented: presentedLeaf, pinned: pinned) ? .accept : .rejectMismatch
    }

    /// Full-certificate pin equality. Used directly by the iOS trust challenge and retained on macOS as
    /// the reference predicate behind curl's public-key pin.
    public static func matches(presented: Data?, pinned: Data?) -> Bool {
        guard let presented, let pinned else { return false }
        return presented == pinned
    }

    /// SHA-256 (base64) of the pinned certificate's SubjectPublicKeyInfo — exactly what curl's
    /// `--pinnedpubkey` hashes (verified against a live host: a mismatched pin makes curl exit 90).
    public static func publicKeyPinHash(for certificateDER: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let key = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else { return nil }
        return Data(SHA256.hash(data: spkiWrappingRSA(pkcs1))).base64EncodedString()
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
}

/// Shared by both transports so the capture path is identical regardless of how the request was made.
enum TransportCapture {
    #if DEBUG
    static func captureIfEnabled(_ data: Data, path: String, query: [URLQueryItem]) {
        guard let dir = ProcessInfo.processInfo.environment["ASTERIA_CAPTURE_DIR"] else { return }
        let phrase = query.first { $0.name == "phrase" }?.value
        let name = phrase.map { "\(path)-\($0)" } ?? path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).xml"))
    }
    #else
    static func captureIfEnabled(_ data: Data, path: String, query: [URLQueryItem]) {}
    #endif
}

/// The request URL both transports build; kept here so host/port/scheme rules can't drift between them.
enum GameStreamURL {
    static func make(host: String, secure: Bool, httpPort: UInt16, httpsPort: UInt16,
                     path: String, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.host = host
        components.port = Int(secure ? httpsPort : httpPort)
        components.path = "/" + path
        components.queryItems = query
        guard let url = components.url else { throw PairingError.transport("invalid URL") }
        return url
    }
}
