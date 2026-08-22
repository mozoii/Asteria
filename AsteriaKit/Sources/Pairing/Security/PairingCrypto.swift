import Foundation
import CryptoKit

/// Crypto primitives for the GameStream PIN pairing handshake.
public enum PairingCrypto {
    /// AES-128 key: SHA-256(salt + PIN) truncated to 16 bytes.
    public static func aesKey(salt: [UInt8], pin: String) -> [UInt8] {
        var input = Data(salt)
        input.append(contentsOf: Array(pin.utf8))
        return Array(SHA256.hash(data: input).prefix(16))
    }

    public static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(data)))
    }
}
