import Foundation
import Testing
@testable import AsteriaCore

@Suite("Client fingerprint")
struct ClientFingerprintTests {
    @Test("accepts exactly 32 digest bytes and presents eight characters")
    func digest() throws {
        let bytes = [UInt8](repeating: 0xAB, count: 32)
        let fingerprint = try #require(ClientFingerprint(sha256Digest: bytes))

        #expect(fingerprint.rawValue == String(repeating: "ab", count: 32))
        #expect(fingerprint.shortDisplay == "ABABABAB")
    }

    @Test("rejects malformed string representations")
    func validation() {
        #expect(ClientFingerprint(rawValue: String(repeating: "a", count: 63)) == nil)
        #expect(ClientFingerprint(rawValue: String(repeating: "A", count: 64)) == nil)
        #expect(ClientFingerprint(rawValue: String(repeating: "z", count: 64)) == nil)
    }

    @Test("decoding rejects an invalid persisted fingerprint")
    func decodeValidation() {
        let data = Data(#""not-a-fingerprint""#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ClientFingerprint.self, from: data)
        }
    }
}
