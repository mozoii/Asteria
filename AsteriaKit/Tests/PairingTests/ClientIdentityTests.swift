import Foundation
import Testing
@testable import Pairing

@Suite("Client identity (RSA-2048 self-signed)")
struct ClientIdentityTests {
    @Test("Fingerprint is the lowercase SHA-256 certificate DER digest")
    func fingerprint() throws {
        let identity = try ClientIdentity.generate()

        #expect(identity.fingerprint.rawValue == identity.fingerprint.rawValue.lowercased())
        #expect(identity.fingerprint.rawValue.count == 64)
        #expect(identity.fingerprint.rawValue.allSatisfy { $0.isHexDigit })
        #expect(identity.uniqueId == String(identity.fingerprint.rawValue.prefix(16)))
    }
    @Test func generatesValidSelfSignedCert() throws {
        let id = try ClientIdentity.generate()
        #expect(id.certificatePEM.contains("BEGIN CERTIFICATE"))
        #expect(id.privateKeyPEM.contains("PRIVATE KEY"))
        #expect(id.certificateDER.count > 500)
    }

    @Test func eachIdentityIsUnique() throws {
        let a = try ClientIdentity.generate()
        let b = try ClientIdentity.generate()
        #expect(a.certificatePEM != b.certificatePEM)
    }

    // RSA-2048 signatures: 256 bytes, used in challenge-response hash
    @Test func extractsSignatureBytes() throws {
        let id = try ClientIdentity.generate()
        let sig = try id.signatureBytes()
        #expect(sig.count == 256)
    }
}
