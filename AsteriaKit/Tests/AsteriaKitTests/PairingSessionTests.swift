import Foundation
import Testing
import X509
import SwiftASN1
@testable import AsteriaKit
@testable import Pairing
import AsteriaModel

/// Simulated Sunshine host: drives the full 5-stage handshake from the server side.
private actor SimulatedSunshine: GameStreamTransport {
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
        if secure { return root("<paired>1</paired>") }   // stage 5

        if value(query, "phrase") == "getservercert" {
            let salt = Hex.decode(value(query, "salt")!)!
            serverKey = PairingCrypto.aesKey(salt: salt, pin: realPin)
            let pem = String(decoding: Hex.decode(value(query, "clientcert")!)!, as: UTF8.self)
            let cert = try Certificate(pemEncoded: pem)
            var serializer = DER.Serializer(); try serializer.serialize(cert)
            clientCertSig = try ClientIdentity
                .extractSignature(fromCertificateDER: serializer.serializedBytes)
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
            let serverSignature = [UInt8](repeating: 0, count: 256)
            let secret = serverSecret + serverSignature
            return root("<pairingsecret>\(Hex.encode(secret))</pairingsecret>")
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

private struct FailingTransport: GameStreamTransport {
    func get(secure: Bool, path: String, query: [URLQueryItem]) async throws -> Data {
        throw PairingError.transport("boom")
    }
}

private func collect(_ session: PairingSession) async -> [PairingProgress] {
    var progress: [PairingProgress] = []
    for await event in session.run() { progress.append(event) }
    return progress
}

@Suite("Pairing session")
struct PairingSessionTests {
    private let host = HostRecord(id: "uid", name: "PC", address: "127.0.0.1")

    private func session(
        realPin: String? = nil,
        clientPin: String = "0314",
        onPaired: @escaping @Sendable (HostRecord) async -> Void = { _ in }
    ) throws -> PairingSession {
        let identities = ClientIdentityVault(secretStore: InMemorySecretStore())
        if let realPin {
            let server = try SimulatedSunshine(realPin: realPin)
            return PairingSession(
                host: host,
                identities: identities,
                onPaired: onPaired,
                dependencies: PairingSessionDependencies(
                    transportFactory: { _, _ in server },
                    pinGenerator: { clientPin }
                )
            )
        }
        return PairingSession(
            host: host,
            identities: identities,
            onPaired: onPaired,
            dependencies: PairingSessionDependencies(
                transportFactory: { _, _ in FailingTransport() },
                pinGenerator: { clientPin }
            )
        )
    }

    @Test("progress reaches awaitingPIN with a deadline before a transport failure")
    func transportFailureYieldsPinThenFailure() async throws {
        let progress = await collect(try session())
        guard case let .awaitingPIN(pin, deadline) = progress[1] else {
            Issue.record("expected awaitingPIN, got \(progress)")
            return
        }
        #expect(pin.count == 4)
        #expect(deadline > Date())
        #expect(progress.last == .failed(message: "Couldn't reach the PC: boom"))
    }

    @Test("wrong PIN fails with the canonical mismatch message")
    func wrongPinYieldsMismatch() async throws {
        let session = try session(realPin: "0314", clientPin: "9999")
        let progress = await collect(session)
        let failedMessages = progress.compactMap { progress in
            if case let .failed(message) = progress { message } else { nil }
        }
        #expect(failedMessages.contains { $0.contains("PIN didn't match") })
    }

    @Test("correct PIN persists identity and marks the host paired")
    func correctPinPersistsAndPairs() async throws {
        let store = InMemorySecretStore()
        let identities = ClientIdentityVault(secretStore: store)
        let paired = AtomicPairedBox()
        let server = try SimulatedSunshine(realPin: "0314")
        let session = PairingSession(
            host: host,
            identities: identities,
            onPaired: { updated in await paired.set(updated) },
            dependencies: PairingSessionDependencies(
                transportFactory: { _, _ in server },
                pinGenerator: { "0314" }
            )
        )
        let progress = await collect(session)

        guard case let .paired(fingerprint) = progress.last else {
            Issue.record("expected paired, got \(progress)")
            return
        }
        let updated = await paired.value
        #expect(updated?.isPaired == true)
        #expect(updated?.pinnedCertificate?.isEmpty == false)
        #expect(updated?.clientFingerprint == fingerprint)
        let key = "client-identity-pem.\(fingerprint.rawValue)"
        #expect(try store.data(forKey: key) != nil)
    }
}

private actor AtomicPairedBox {
    private var host: HostRecord?
    func set(_ host: HostRecord) { self.host = host }
    var value: HostRecord? { host }
}
