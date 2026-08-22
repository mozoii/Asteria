import Foundation
import Testing
@testable import Pairing

@Suite("Pairing crypto (golden vectors)")
struct PairingCryptoTests {
    // Golden: SHA-256(0x00..0x0f ‖ "1234")[0:16]
    @Test func aesKeyDerivationMatchesGolden() {
        let salt = Array(UInt8(0)...UInt8(15))
        let key = PairingCrypto.aesKey(salt: salt, pin: "1234")
        #expect(key.count == 16)
        #expect(Hex.encode(key) == "bad0b4f7cae08eb7c1b5acc763a8ed25")
    }

    // NIST AES-128-ECB known-answer vector
    @Test func aesEcbNistVector() throws {
        let key = Hex.decode("2b7e151628aed2a6abf7158809cf4f3c")!
        let plaintext = Hex.decode("6bc1bee22e409f96e93d7e117393172a")!
        let ciphertext = try AESECB.encrypt(plaintext, key: key)
        #expect(Hex.encode(ciphertext) == "3ad77bb40d7a3660a89ecaf32466ef97")
        #expect(try AESECB.decrypt(ciphertext, key: key) == plaintext)
    }

    @Test func aesEcbRejectsNonBlockSizedInput() {
        #expect(throws: AESECBError.self) {
            try AESECB.encrypt([1, 2, 3], key: Array(repeating: 0, count: 16))
        }
    }

    @Test func hexRoundTrips() {
        #expect(Hex.decode("00ff10")! == [0, 255, 16])
        #expect(Hex.encode([0, 255, 16]) == "00ff10")
        #expect(Hex.decode("abc") == nil)
        #expect(Hex.decode("zz") == nil)
    }
}
