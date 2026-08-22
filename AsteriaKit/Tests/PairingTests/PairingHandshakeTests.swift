import Foundation
import Testing
@testable import Pairing

@Suite("Pairing handshake (crypto round-trip)")
struct PairingHandshakeTests {
    @Test func correctPinProducesMutualProof() throws {
        let salt = PairingRandom.bytes(16)
        let key = PairingCrypto.aesKey(salt: salt, pin: "4321")
        let client = PairingHandshake(aesKey: key)
        let server = PairingHandshake(aesKey: key)

        let serverCertSig = PairingRandom.bytes(256)
        let clientCertSig = PairingRandom.bytes(256)

        let clientChallenge = PairingRandom.bytes(16)
        let enc2 = try client.encryptClientChallenge(clientChallenge)
        let recovered = try AESECB.decrypt(enc2, key: key)
        #expect(recovered == clientChallenge)

        let serverChallenge = PairingRandom.bytes(16)
        let serverSecret = PairingRandom.bytes(16)
        let serverHash = server.digest(recovered + serverCertSig + serverSecret)
        let encResp = try AESECB.encrypt(serverHash + serverChallenge, key: key)

        let (gotHash, gotChallenge) = try client.decryptServerChallengeResponse(encResp)
        #expect(gotChallenge == serverChallenge)
        #expect(client.isServerHashValid(
            serverHash: gotHash, clientChallenge: clientChallenge,
            serverCertSignature: serverCertSig, serverSecret: serverSecret))

        let clientSecret = PairingRandom.bytes(16)
        let enc3 = try client.encryptChallengeResponse(
            serverChallenge: gotChallenge, clientCertSignature: clientCertSig, clientSecret: clientSecret)
        let dec3 = try AESECB.decrypt(enc3, key: key)
        let expectedClientHash = server.digest(serverChallenge + clientCertSig + clientSecret)
        #expect(Array(dec3.prefix(32)) == expectedClientHash)
    }

    @Test func wrongPinFailsServerVerification() throws {
        let salt = PairingRandom.bytes(16)
        let serverKey = PairingCrypto.aesKey(salt: salt, pin: "1111")
        let clientKey = PairingCrypto.aesKey(salt: salt, pin: "2222")
        let client = PairingHandshake(aesKey: clientKey)
        let serverCertSig = PairingRandom.bytes(256)

        let clientChallenge = PairingRandom.bytes(16)
        let enc2 = try client.encryptClientChallenge(clientChallenge)

        let recovered = try AESECB.decrypt(enc2, key: serverKey)
        let serverChallenge = PairingRandom.bytes(16)
        let serverSecret = PairingRandom.bytes(16)
        let serverHash = PairingHandshake(aesKey: serverKey).digest(recovered + serverCertSig + serverSecret)
        let encResp = try AESECB.encrypt(serverHash + serverChallenge, key: serverKey)

        let (gotHash, _) = try client.decryptServerChallengeResponse(encResp)
        #expect(!client.isServerHashValid(
            serverHash: gotHash, clientChallenge: clientChallenge,
            serverCertSignature: serverCertSig, serverSecret: serverSecret))
    }
}
