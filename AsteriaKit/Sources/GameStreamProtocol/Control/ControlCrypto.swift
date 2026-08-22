import Foundation
import CryptoKit

/// Encrypts/decrypts control-stream messages with AES-128-GCM.
public struct ControlCrypto: Sendable {
    public enum Origin: UInt8 { case client = 0x43 /* 'C' */, host = 0x48 /* 'H' */ }

    private let key: SymmetricKey

    public init(rikey: [UInt8]) {
        self.key = SymmetricKey(data: Data(rikey))
    }

    /// The 12-byte AES-GCM IV for a given sequence number + originator. The layout (seq LE in bytes 0-3,
    /// originator in byte 10, fixed 0x43 in byte 11) is fixed by the Sunshine wire protocol and must byte-match the host.
    static func iv(seq: UInt32, origin: Origin) -> [UInt8] {
        var iv = [UInt8](repeating: 0, count: 12)
        iv[0] = UInt8(seq & 0xff)
        iv[1] = UInt8((seq >> 8) & 0xff)
        iv[2] = UInt8((seq >> 16) & 0xff)
        iv[3] = UInt8((seq >> 24) & 0xff)
        iv[10] = origin.rawValue
        iv[11] = 0x43
        return iv
    }

    /// Encrypt a control message into a full wire packet.
    public func seal(type: UInt16, payload: [UInt8], seq: UInt32, origin: Origin = .client) throws -> [UInt8] {
        var plaintext = [UInt8]()
        plaintext.reserveCapacity(4 + payload.count)
        plaintext.append(contentsOf: le16(type))
        plaintext.append(contentsOf: le16(UInt16(payload.count)))
        plaintext.append(contentsOf: payload)

        let nonce = try AES.GCM.Nonce(data: Data(Self.iv(seq: seq, origin: origin)))
        let sealed = try AES.GCM.seal(Data(plaintext), using: key, nonce: nonce)
        let tag = Array(sealed.tag)
        let ciphertext = Array(sealed.ciphertext)

        let length = UInt16(4 /*seq*/ + tag.count + ciphertext.count)
        var packet = [UInt8]()
        packet.reserveCapacity(4 + Int(length))
        packet.append(contentsOf: le16(0x0001))
        packet.append(contentsOf: le16(length))
        packet.append(contentsOf: le32(seq))
        packet.append(contentsOf: tag)
        packet.append(contentsOf: ciphertext)
        return packet
    }

    /// Decrypt a wire packet.
    public func open(_ packet: [UInt8], origin: Origin = .host) throws -> (type: UInt16, payload: [UInt8]) {
        guard packet.count >= 8 else { throw ControlCryptoError.malformed }
        let headerType = UInt16(packet[0]) | (UInt16(packet[1]) << 8)
        guard headerType == 0x0001 else { throw ControlCryptoError.malformed }
        let seq = UInt32(packet[4]) | (UInt32(packet[5]) << 8) | (UInt32(packet[6]) << 16) | (UInt32(packet[7]) << 24)
        let body = Array(packet[8...])
        guard body.count >= 16 + 4 else { throw ControlCryptoError.malformed }
        let tag = Array(body[0..<16])
        let ciphertext = Array(body[16...])

        let nonce = try AES.GCM.Nonce(data: Data(Self.iv(seq: seq, origin: origin)))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
        let plaintext = Array(try AES.GCM.open(box, using: key))

        guard plaintext.count >= 4 else { throw ControlCryptoError.malformed }
        let type = UInt16(plaintext[0]) | (UInt16(plaintext[1]) << 8)
        let payloadLength = Int(UInt16(plaintext[2]) | (UInt16(plaintext[3]) << 8))
        let payload = Array(plaintext[4..<min(4 + payloadLength, plaintext.count)])
        return (type, payload)
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
}

public enum ControlCryptoError: Error { case malformed }
