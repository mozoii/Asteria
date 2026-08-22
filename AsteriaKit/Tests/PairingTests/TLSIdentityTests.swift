import Foundation
import Security
import Testing
@testable import Pairing

/// Regression coverage: the keychain must resolve an identity whose certificate is byte-identical to
/// the certificate the pairing handshake registers with the host. A mismatch (stale/foreign cert
/// paired with the tagged key) makes Sunshine-family hosts reject the pair challenge with
/// "Certificate verification failed".
@Suite("Keychain-backed TLS identity")
struct TLSIdentityTests {
    @Test("makeTLSIdentity presents exactly the identity's certificate")
    func presentsIdentityCertificate() throws {
        let commonName = "AsteriaTest-\(UUID().uuidString)"
        let identity = try ClientIdentity.createKeychainBacked(commonName: commonName)
        defer {
            SecItemDelete([
                kSecClass: kSecClassKey,
                kSecAttrApplicationTag: identity.keychainKeyTag,
            ] as CFDictionary)
            SecItemDelete([
                kSecClass: kSecClassCertificate,
                kSecAttrLabel: commonName,
            ] as CFDictionary)
        }

        let tls = try identity.makeTLSIdentity()

        var certRef: SecCertificate?
        #expect(SecIdentityCopyCertificate(tls.secIdentity, &certRef) == errSecSuccess)
        let presentedDER = try #require(certRef).map { SecCertificateCopyData($0) as Data }
        #expect(presentedDER == Data(identity.certificateDER))
    }

    @Test("identity reloaded from PEM resolves the same keychain certificate")
    func reloadedIdentityPresentsSameCertificate() throws {
        let commonName = "AsteriaTest-\(UUID().uuidString)"
        let identity = try ClientIdentity.createKeychainBacked(commonName: commonName)
        defer {
            SecItemDelete([
                kSecClass: kSecClassKey,
                kSecAttrApplicationTag: identity.keychainKeyTag,
            ] as CFDictionary)
            SecItemDelete([
                kSecClass: kSecClassCertificate,
                kSecAttrLabel: commonName,
            ] as CFDictionary)
        }

        let reloaded = try ClientIdentity.load(fromPEM: identity.combinedPEM)
        let tls = try reloaded.makeTLSIdentity()

        var certRef: SecCertificate?
        #expect(SecIdentityCopyCertificate(tls.secIdentity, &certRef) == errSecSuccess)
        let presentedDER = try #require(certRef).map { SecCertificateCopyData($0) as Data }
        #expect(presentedDER == Data(identity.certificateDER))
    }
}
