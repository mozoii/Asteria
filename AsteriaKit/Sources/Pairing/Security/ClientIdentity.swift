import Foundation
import X509
import SwiftASN1
import Crypto
import _CryptoExtras
import AsteriaCore

/// Self-signed RSA-2048 X.509 identity. Required for GameStream pairing and HTTPS mutual-TLS.
public struct ClientIdentity: @unchecked Sendable {
    public let certificatePEM: String
    public let certificateDER: [UInt8]
    public let privateKey: _RSA.Signing.PrivateKey

    public var privateKeyPEM: String { privateKey.pemRepresentation }

    /// Certificate + private key in one PEM blob — the format used on disk and in the Keychain.
    public var combinedPEM: String { certificatePEM + "\n" + privateKeyPEM + "\n" }

    /// Stable per-identity client id (hex of SHA-256(cert)[0:8]) — survives across launches.
    public var uniqueId: String { String(fingerprint.rawValue.prefix(16)) }

    /// Stable profile identity matching the client certificate trusted by Sunshine-family hosts.
    public var fingerprint: ClientFingerprint {
        let digest = SHA256.hash(data: Data(certificateDER))
        guard let fingerprint = ClientFingerprint(sha256Digest: digest) else {
            preconditionFailure("SHA-256 produced an invalid client fingerprint")
        }
        return fingerprint
    }


    public func save(toFile url: URL) throws {
        try combinedPEM.write(to: url, atomically: true, encoding: .utf8)
        // The file holds the RSA private key — keep it owner-only (0600), not world-readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(fromFile url: URL) throws -> ClientIdentity {
        try load(fromPEM: try String(contentsOf: url, encoding: .utf8))
    }

    /// Parse a combined certificate + RSA private-key PEM (the on-disk / Keychain identity format).
    public static func load(fromPEM combined: String) throws -> ClientIdentity {
        guard let certStart = combined.range(of: "-----BEGIN CERTIFICATE-----"),
              let certEnd = combined.range(of: "-----END CERTIFICATE-----") else {
            throw PairingError.malformedCertificate
        }
        let certPEM = String(combined[certStart.lowerBound...certEnd.upperBound])
        let keyPEM = String(combined[certEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rsa = try _RSA.Signing.PrivateKey(pemRepresentation: keyPEM)
        let cert = try Certificate(pemEncoded: certPEM)
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        return ClientIdentity(certificatePEM: certPEM, certificateDER: serializer.serializedBytes, privateKey: rsa)
    }

    public init(certificatePEM: String, certificateDER: [UInt8], privateKey: _RSA.Signing.PrivateKey) {
        self.certificatePEM = certificatePEM
        self.certificateDER = certificateDER
        self.privateKey = privateKey
    }

    /// Generate a fresh self-signed RSA-2048 identity (20-year validity), key held in memory only.
    /// Sunshine-family hosts do not validate the common name; it is Asteria's own identity label.
    public static func generate(commonName: String = "Asteria Client") throws -> ClientIdentity {
        let rsa = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let parts = try selfSignedCertificate(commonName: commonName, privateKey: rsa)
        return ClientIdentity(
            certificatePEM: parts.pem,
            certificateDER: parts.der,
            privateKey: rsa
        )
    }

    /// Mint a 20-year self-signed certificate around an existing RSA private key.
    static func selfSignedCertificate(
        commonName: String,
        privateKey rsa: _RSA.Signing.PrivateKey
    ) throws -> (pem: String, der: [UInt8]) {
        let key = Certificate.PrivateKey(rsa)

        let name = try DistinguishedName {
            CommonName(commonName)
        }

        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 365 * 20),
            issuer: name,
            subject: name,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: Certificate.Extensions {},
            issuerPrivateKey: key
        )

        var serializer = DER.Serializer()
        try serializer.serialize(certificate)

        return (try certificate.serializeAsPEM().pemString, serializer.serializedBytes)
    }

    /// X.509 `signatureValue` bytes (used in pairing challenge-response).
    public func signatureBytes() throws -> [UInt8] {
        try Self.extractSignature(fromCertificateDER: certificateDER)
    }

    /// PKCS#1 v1.5 SHA-256 RSA signature.
    public func sign(_ data: [UInt8]) throws -> [UInt8] {
        let signature = try privateKey.signature(for: SHA256.hash(data: Data(data)), padding: .insecurePKCS1v1_5)
        return Array(signature.rawRepresentation)
    }

    /// Extract `signatureValue` BIT STRING from a DER X.509 certificate.
    static func extractSignature(fromCertificateDER der: [UInt8]) throws -> [UInt8] {
        let root = try DER.parse(der)
        guard case .constructed(let nodes) = root.content else { throw PairingError.malformedCertificate }
        let children = Array(nodes)
        guard children.count == 3 else { throw PairingError.malformedCertificate }
        let bitString = try ASN1BitString(derEncoded: children[2])
        return Array(bitString.bytes)
    }
}
