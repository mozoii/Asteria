import Foundation
import Testing
@testable import Pairing

@Suite("PairingFlow — pure stage machine")
struct PairingFlowTests {
    private func value(_ q: [URLQueryItem], _ name: String) -> String? { q.first { $0.name == name }?.value }
    private func root(_ inner: String) -> Data { Data("<root status_code=\"200\">\(inner)</root>".utf8) }

    private func makeFlow() throws -> PairingFlow {
        let identity = try ClientIdentity.generate()
        let salt = Array<UInt8>(repeating: 0xAB, count: 16)
        return try PairingFlow(
            identity: identity,
            handshake: PairingHandshake(aesKey: PairingCrypto.aesKey(salt: salt, pin: "0314")),
            deviceName: "Asteria",
            uniqueId: "abcd1234",
            salt: salt,
            clientChallenge: Array(0..<16),
            clientSecret: Array(16..<32)
        )
    }

    @Test func stage1RequestCarriesSaltCertAndPhrase() throws {
        let flow = try makeFlow()
        let req = flow.clientCertRequest()
        #expect(req.secure == false)
        #expect(req.path == "pair")
        #expect(value(req.query, "phrase") == "getservercert")
        #expect(value(req.query, "salt") == String(repeating: "ab", count: 16))
        #expect(value(req.query, "uniqueid") == "abcd1234")
        #expect(value(req.query, "clientname") == "Asteria")
        #expect(value(req.query, "clientcert") != nil)
    }

    @Test func stage1WrongPinSurfacesAsMismatch() throws {
        var flow = try makeFlow()
        #expect(throws: PairingError.self) {
            try flow.ingestServerCert(root("<paired>0</paired>"))
        }
    }

    @Test func stage3BeforeStage2Throws() throws {
        let flow = try makeFlow()
        #expect(throws: PairingError.self) {
            _ = try flow.serverChallengeRespRequest()
        }
    }

    @Test func stage2RequestEncryptsTheClientChallenge() throws {
        let flow = try makeFlow()
        let req = try flow.clientChallengeRequest()
        let ccHex = try #require(value(req.query, "clientchallenge"))
        let cipher = try #require(Hex.decode(ccHex))
        #expect(cipher.count == 16)
        #expect(cipher != Array(0..<16))
    }

    @Test func stage5RequestIsHttpsPairChallenge() throws {
        let flow = try makeFlow()
        let req = flow.pairChallengeRequest()
        #expect(req.secure == true)
        #expect(value(req.query, "phrase") == "pairchallenge")
    }

    @Test func stage5RejectionSurfacesVerificationFailure() throws {
        let flow = try makeFlow()
        #expect(throws: PairingError.serverVerificationFailed) {
            try flow.ingestPairChallenge(root("<paired>0</paired>"))
        }
    }
}
