import Foundation
import Testing
@testable import GameStreamProtocol

@Suite("Control stream encryption (AES-GCM control-v2)")
struct ControlCryptoTests {
    private let key = Array<UInt8>(0..<16)   // stand-in rikey

    @Test func sealLayoutMatchesWireFormat() throws {
        let crypto = ControlCrypto(rikey: key)
        let payload: [UInt8] = [0xAA, 0xBB, 0xCC]
        let packet = try crypto.seal(type: 0x0305, payload: payload, seq: 1)

        // [encryptedHeaderType u16 LE = 0x0001][length u16 LE][seq u32 LE][tag 16][ciphertext]
        #expect(packet[0] == 0x01 && packet[1] == 0x00)             // 0x0001 LE
        let length = UInt16(packet[2]) | (UInt16(packet[3]) << 8)
        // length = seq(4) + tag(16) + v2header(4) + payloadLength(3)
        #expect(length == 4 + 16 + 4 + UInt16(payload.count))
        let seq = UInt32(packet[4]) | (UInt32(packet[5]) << 8) | (UInt32(packet[6]) << 16) | (UInt32(packet[7]) << 24)
        #expect(seq == 1)
        // Total = encryptedHeaderType(2) + length field(2) + length
        #expect(packet.count == 2 + 2 + Int(length))
    }

    @Test func openReversesSeal() throws {
        let crypto = ControlCrypto(rikey: key)
        let payload = Array("hello-control".utf8)
        let hostPacket = try crypto.seal(type: 0x0204, payload: payload, seq: 42, origin: .host)
        let opened = try crypto.open(hostPacket)
        #expect(opened.type == 0x0204)
        #expect(opened.payload == payload)
    }

    @Test func emptyPayloadRoundTrips() throws {
        let crypto = ControlCrypto(rikey: key)
        let packet = try crypto.seal(type: 0x0109, payload: [], seq: 7, origin: .host)
        let opened = try crypto.open(packet)
        #expect(opened.type == 0x0109)
        #expect(opened.payload.isEmpty)
    }

    @Test func ivEncodesSeqAndOrigin() {
        let clientIV = ControlCrypto.iv(seq: 0x01020304, origin: .client)
        #expect(clientIV == [0x04, 0x03, 0x02, 0x01, 0, 0, 0, 0, 0, 0, 0x43, 0x43])  // 'C','C'
        let hostIV = ControlCrypto.iv(seq: 1, origin: .host)
        #expect(hostIV == [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x48, 0x43])                // 'H','C'
    }

    @Test func tamperedTagFailsToOpen() throws {
        let crypto = ControlCrypto(rikey: key)
        var packet = try crypto.seal(type: 0x0305, payload: [1, 2, 3], seq: 1, origin: .host)
        packet[10] ^= 0xFF   // flip a tag byte
        #expect(throws: (any Error).self) { _ = try crypto.open(packet) }
    }
}
