import Foundation
import X509
import SwiftASN1
import AsteriaCore

/// A pairing handshake request: secure flag, path, and query parameters.
struct PairingRequest: Sendable, Equatable {
    let secure: Bool
    let path: String
    let query: [URLQueryItem]
}

extension GameStreamTransport {
    /// Issue a `PairingRequest` over the transport's I/O seam.
    func get(_ request: PairingRequest) async throws -> Data {
        try await get(secure: request.secure, path: request.path, query: request.query)
    }
}

/// Pure 5-stage GameStream PIN pairing state machine; randomness and PIN-derived key are injected for testability.
struct PairingFlow {
    private let identity: ClientIdentity
    private let handshake: PairingHandshake
    private let deviceName: String
    private let uniqueId: String
    private let salt: [UInt8]
    private let clientChallenge: [UInt8]
    private let clientSecret: [UInt8]

    private let clientCertSignature: [UInt8]

    private(set) var serverCertificateDER: [UInt8]?
    private var serverCertSignature: [UInt8]?
    private var serverChallenge: [UInt8]?
    private var serverHash: [UInt8]?
    private var serverSecret: [UInt8]?

    init(
        identity: ClientIdentity,
        handshake: PairingHandshake,
        deviceName: String,
        uniqueId: String,
        salt: [UInt8],
        clientChallenge: [UInt8],
        clientSecret: [UInt8]
    ) throws {
        self.identity = identity
        self.handshake = handshake
        self.deviceName = deviceName
        self.uniqueId = uniqueId
        self.salt = salt
        self.clientChallenge = clientChallenge
        self.clientSecret = clientSecret
        self.clientCertSignature = try identity.signatureBytes()
    }

    private func request(secure: Bool = false, _ extra: [(String, String)]) -> PairingRequest {
        PairingRequest(secure: secure, path: "pair",
                       query: HostQuery.base(uniqueId: uniqueId, [
                           ("devicename", deviceName),
                           ("clientname", deviceName),
                           ("updateState", "1"),
                       ] + extra))
    }

    func clientCertRequest() -> PairingRequest {
        request([
            ("phrase", "getservercert"),
            ("salt", Hex.encode(salt)),
            ("clientcert", Hex.encode(Array(identity.certificatePEM.utf8))),
        ])
    }

    mutating func ingestServerCert(_ data: Data) throws {
        guard let xml = try? FlatXML(parsing: data),
              xml.int("paired") == 1,
              let plaincertHex = xml.value("plaincert"),
              let serverCertPEMBytes = Hex.decode(plaincertHex) else {
            throw PairingError.pinMismatch
        }
        let serverCert = try Certificate(pemEncoded: String(decoding: serverCertPEMBytes, as: UTF8.self))
        var serializer = DER.Serializer()
        try serializer.serialize(serverCert)
        serverCertificateDER = serializer.serializedBytes
        serverCertSignature = try ClientIdentity.extractSignature(fromCertificateDER: serializer.serializedBytes)
    }

    func clientChallengeRequest() throws -> PairingRequest {
        request([("clientchallenge", Hex.encode(try handshake.encryptClientChallenge(clientChallenge)))])
    }

    mutating func ingestChallengeResponse(_ data: Data) throws {
        guard let xml = try? FlatXML(parsing: data),
              let crHex = xml.value("challengeresponse"), let crBytes = Hex.decode(crHex) else {
            throw PairingError.malformedResponse("missing challengeresponse")
        }
        (serverHash, serverChallenge) = try handshake.decryptServerChallengeResponse(crBytes)
    }

    func serverChallengeRespRequest() throws -> PairingRequest {
        guard let serverChallenge else { throw PairingError.malformedResponse("serverchallengeresp before clientchallenge") }
        let encrypted = try handshake.encryptChallengeResponse(
            serverChallenge: serverChallenge,
            clientCertSignature: clientCertSignature,
            clientSecret: clientSecret
        )
        return request([("serverchallengeresp", Hex.encode(encrypted))])
    }

    mutating func ingestPairingSecret(_ data: Data) throws {
        guard let xml = try? FlatXML(parsing: data),
              let psHex = xml.value("pairingsecret"), let ps = Hex.decode(psHex), ps.count >= 16 else {
            throw PairingError.malformedResponse("missing pairingsecret")
        }
        // ps[0..<16] is the server secret; ps[16...] is its RSA signature.
        let secret = Array(ps[0..<16])
        serverSecret = secret
        guard let serverCertSignature, let serverHash else {
            throw PairingError.malformedResponse("pairingsecret before server cert / challenge")
        }
        guard handshake.isServerHashValid(
            serverHash: serverHash,
            clientChallenge: clientChallenge,
            serverCertSignature: serverCertSignature,
            serverSecret: secret
        ) else {
            throw PairingError.pinMismatch
        }
    }

    func clientPairingSecretRequest() throws -> PairingRequest {
        let clientPairingSecret = clientSecret + (try identity.sign(clientSecret))
        return request([("clientpairingsecret", Hex.encode(clientPairingSecret))])
    }

    func ingestPairedConfirmation(_ data: Data) throws {
        guard (try? FlatXML(parsing: data))?.int("paired") == 1 else { throw PairingError.pinMismatch }
    }

    func pairChallengeRequest() -> PairingRequest {
        request(secure: true, [("phrase", "pairchallenge")])
    }

    func ingestPairChallenge(_ data: Data) throws {
        guard (try? FlatXML(parsing: data))?.int("paired") == 1 else { throw PairingError.serverVerificationFailed }
    }
}
