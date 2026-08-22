import Foundation
import Testing
import X509
import SwiftASN1
@testable import Pairing

actor SimulatedSunshine: GameStreamTransport {
    private let realPin: String
    private let serverIdentity: ClientIdentity
    private let serverCertSig: [UInt8]

    private var serverKey: [UInt8] = []
    private var serverChallenge: [UInt8] = []
    private var serverSecret: [UInt8] = []
    private var clientResponseHash: [UInt8] = []
    private var clientCertSig: [UInt8] = []

    init(realPin: String) throws {
        self.realPin = realPin
        self.serverIdentity = try ClientIdentity.generate(commonName: "Sunshine")
        self.serverCertSig = try serverIdentity.signatureBytes()
    }

    private func value(_ query: [URLQueryItem], _ name: String) -> String? {
        query.first { $0.name == name }?.value
    }
    private func root(_ inner: String) -> Data {
        Data("<root status_code=\"200\">\(inner)</root>".utf8)
    }

    func get(secure: Bool, path: String, query: [URLQueryItem]) async throws -> Data {
        // Every secure request succeeds; covers pairing stage 5 (pairchallenge) and beyond.
        if secure { return root("<paired>1</paired>") }

        if value(query, "phrase") == "getservercert" {
            let salt = Hex.decode(value(query, "salt")!)!
            serverKey = PairingCrypto.aesKey(salt: salt, pin: realPin)
            let clientCertPEM = String(decoding: Hex.decode(value(query, "clientcert")!)!, as: UTF8.self)
            let cert = try Certificate(pemEncoded: clientCertPEM)
            var serializer = DER.Serializer(); try serializer.serialize(cert)
            clientCertSig = try ClientIdentity.extractSignature(fromCertificateDER: serializer.serializedBytes)
            let plaincert = Hex.encode(Array(serverIdentity.certificatePEM.utf8))
            return root("<paired>1</paired><plaincert>\(plaincert)</plaincert>")
        }

        if let ccHex = value(query, "clientchallenge") {
            let clientChallenge = try AESECB.decrypt(Hex.decode(ccHex)!, key: serverKey)
            serverChallenge = PairingRandom.bytes(16)
            serverSecret = PairingRandom.bytes(16)
            let serverHash = PairingHandshake(aesKey: serverKey)
                .digest(clientChallenge + serverCertSig + serverSecret)
            let response = try AESECB.encrypt(serverHash + serverChallenge, key: serverKey)
            return root("<challengeresponse>\(Hex.encode(response))</challengeresponse>")
        }

        if let scrHex = value(query, "serverchallengeresp") {
            let decrypted = try AESECB.decrypt(Hex.decode(scrHex)!, key: serverKey)
            clientResponseHash = Array(decrypted.prefix(32))
            // Signature verification happens against the real cert at connect time, so the sim can return zeros.
            let serverSignature = [UInt8](repeating: 0, count: 256)
            return root("<pairingsecret>\(Hex.encode(serverSecret + serverSignature))</pairingsecret>")
        }

        if let cpsHex = value(query, "clientpairingsecret") {
            let clientSecret = Array(Hex.decode(cpsHex)!.prefix(16))
            let expected = PairingHandshake(aesKey: serverKey)
                .digest(serverChallenge + clientCertSig + clientSecret)
            let ok = constantTimeEquals(expected, clientResponseHash)
            return root("<paired>\(ok ? 1 : 0)</paired>")
        }

        return root("<paired>0</paired>")
    }
}

@Suite("Pairing client (simulated server)")
struct PairingClientTests {
    @Test func correctPinPairsEndToEnd() async throws {
        let server = try SimulatedSunshine(realPin: "0314")
        let client = PairingClient(transport: server, identity: try ClientIdentity.generate())
        try await client.pair(pin: "0314")
        #expect(await client.serverCertificateDER != nil)
    }

    @Test func wrongPinThrowsMismatch() async throws {
        let server = try SimulatedSunshine(realPin: "0314")
        let client = PairingClient(transport: server, identity: try ClientIdentity.generate())
        await #expect(throws: PairingError.self) {
            _ = try await client.pair(pin: "9999")
        }
    }
}
