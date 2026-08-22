import Foundation
import CryptoKit

public enum PairingHashAlgorithm: Sendable {
    case sha1   // GFE < Gen 7
    case sha256 // Gen 7+ (Sunshine/Apollo)
    public var length: Int { self == .sha256 ? 32 : 20 }
}

/// Crypto primitives for PIN challenge/response encryption and verification.
public struct PairingHandshake: Sendable {
    public let aesKey: [UInt8]
    public let hashAlgorithm: PairingHashAlgorithm

    public init(aesKey: [UInt8], hashAlgorithm: PairingHashAlgorithm = .sha256) {
        self.aesKey = aesKey
        self.hashAlgorithm = hashAlgorithm
    }

    public func digest(_ data: [UInt8]) -> [UInt8] {
        switch hashAlgorithm {
        case .sha256: return Array(SHA256.hash(data: Data(data)))
        case .sha1:   return Array(Insecure.SHA1.hash(data: Data(data)))
        }
    }

    public func encryptClientChallenge(_ challenge: [UInt8]) throws -> [UInt8] {
        try AESECB.encrypt(challenge, key: aesKey)
    }

    public func decryptServerChallengeResponse(_ encrypted: [UInt8]) throws -> (serverHash: [UInt8], serverChallenge: [UInt8]) {
        let decrypted = try AESECB.decrypt(encrypted, key: aesKey)
        let hashLen = hashAlgorithm.length
        guard decrypted.count >= hashLen + 16 else {
            throw PairingError.malformedResponse("challengeresponse too short")
        }
        return (Array(decrypted[0..<hashLen]), Array(decrypted[hashLen..<(hashLen + 16)]))
    }

    public func encryptChallengeResponse(serverChallenge: [UInt8], clientCertSignature: [UInt8], clientSecret: [UInt8]) throws -> [UInt8] {
        let hash = digest(serverChallenge + clientCertSignature + clientSecret)
        return try AESECB.encrypt(Self.padToBlock(hash), key: aesKey)
    }

    public func isServerHashValid(serverHash: [UInt8], clientChallenge: [UInt8], serverCertSignature: [UInt8], serverSecret: [UInt8]) -> Bool {
        let expected = digest(clientChallenge + serverCertSignature + serverSecret)
        return constantTimeEquals(expected, serverHash)
    }

    static func padToBlock(_ data: [UInt8], block: Int = 16) -> [UInt8] {
        let remainder = data.count % block
        return remainder == 0 ? data : data + [UInt8](repeating: 0, count: block - remainder)
    }
}
