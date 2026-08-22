import Foundation
import Security
import Crypto
import _CryptoExtras
import SwiftASN1
import X509

/// Mutual-TLS `SecIdentity` whose private key lives permanently in the classic file-based keychain,
/// shared across transports. Keys are born inside the keychain and looked up by tag; keys imported
/// from bytes cannot be persisted by sandboxed ad-hoc builds (errSecMissingEntitlement).
public final class TLSClientIdentity: @unchecked Sendable {
    public let secIdentity: SecIdentity

    fileprivate init(secIdentity: SecIdentity) {
        self.secIdentity = secIdentity
    }
}

extension ClientIdentity {
    /// Stable per-identity location of the private-key item in the keychain.
    public var keychainKeyTag: Data {
        Data("io.github.mozoii.asteria.tls.\(uniqueId)".utf8)
    }

    /// Generate a fresh identity whose RSA key is born inside the keychain and persisted under the
    /// identity's stable tag, so later launches can resolve it without ever importing key bytes.
    public static func createKeychainBacked(commonName: String = "Asteria Client") throws -> ClientIdentity {
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ] as CFDictionary, &error) else {
            throw PairingError.transport("keychain RSA keygen failed: \(error!.takeRetainedValue())")
        }
        guard let der = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw PairingError.transport("keychain key export failed: \(error!.takeRetainedValue())")
        }
        let rsa = try _RSA.Signing.PrivateKey(derRepresentation: der)
        let parts = try selfSignedCertificate(commonName: commonName, privateKey: rsa)
        let identity = ClientIdentity(
            certificatePEM: parts.pem,
            certificateDER: parts.der,
            privateKey: rsa
        )

        let tag = identity.keychainKeyTag
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
        // The application label is the public-key hash; it is how identity lookups pair a stored
        // key with its certificate. Persisting the key without it makes the file-based keychain
        // recompute a label that matches no certificate, so set it explicitly.
        guard let publicKey = SecKeyCopyPublicKey(secKey),
              let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw PairingError.transport("keychain public-key export failed: \(error!.takeRetainedValue())")
        }
        let status = SecItemAdd([
            kSecClass: kSecClassKey,
            kSecValueRef: secKey,
            kSecAttrApplicationTag: tag,
            kSecAttrApplicationLabel: Data(Insecure.SHA1.hash(data: publicKeyDER)),
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PairingError.transport("keychain key persistence failed (\(status))")
        }
        return identity
    }

    /// Resolve a mutual-TLS identity for this client from the keychain (no key-byte import).
    public func makeTLSIdentity() throws -> TLSClientIdentity {
        let keyTag = keychainKeyTag
        // Verify the key exists before proceeding.
        let keyStatus = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecReturnRef: false,
        ] as CFDictionary, nil)
        guard keyStatus == errSecSuccess else {
            throw PairingError.transport(
                "client TLS key missing from the keychain (\(keyStatus)) — pair the host again")
        }

        guard let certificate = SecCertificateCreateWithData(nil, Data(certificateDER) as CFData) else {
            throw PairingError.malformedCertificate
        }
        // Content-addressed; duplicates are expected with concurrent transports.
        var exportError: Unmanaged<CFError>?
        guard let certificateKey = SecCertificateCopyKey(certificate),
              let certificateKeyDER = SecKeyCopyExternalRepresentation(certificateKey, &exportError) as Data? else {
            throw PairingError.transport("certificate public-key export failed")
        }
        let certStatus = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrApplicationLabel: Data(Insecure.SHA1.hash(data: certificateKeyDER)),
        ] as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw PairingError.transport("SecItemAdd(cert)=\(certStatus)")
        }

        var identityResult: CFTypeRef?
        let queryStatus = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrApplicationTag: keyTag,
            kSecReturnRef: true,
        ] as CFDictionary, &identityResult)
        guard queryStatus == errSecSuccess, let identity = identityResult,
              CFGetTypeID(identity) == SecIdentityGetTypeID() else {
            throw PairingError.transport("SecItemCopyMatching(identity)=\(queryStatus)")
        }
        return TLSClientIdentity(secIdentity: identity as! SecIdentity)
    }
}
