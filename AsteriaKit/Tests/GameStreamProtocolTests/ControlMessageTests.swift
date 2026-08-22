import Testing
@testable import GameStreamProtocol

@Suite("Control message protocol (gen7 encrypted)")
struct ControlMessageTests {
    @Test func startSequenceTypesAndPayloads() {
        #expect(ControlMessage.startA.type == 0x0302)
        #expect(ControlMessage.startA.payload == [0, 0])
        #expect(ControlMessage.startB.type == 0x0307)
        #expect(ControlMessage.startB.payload == [0])
    }

    @Test func periodicPing() {
        #expect(ControlMessage.ping.type == 0x0200)
        #expect(ControlMessage.ping.payload == [0x04, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func channelIds() {
        #expect(ControlMessage.channelGeneric == 0x00)
        #expect(ControlMessage.channelUrgent == 0x01)
        #expect(ControlMessage.channelCount == 0x30)
    }

    @Test func requestIdrSharesStartASlot() {
        // IDR reuses Start A's type/payload.
        #expect(ControlMessage.requestIdr.type == 0x0302)
        #expect(ControlMessage.requestIdr.payload == [0, 0])
    }

    @Test func invalidateReferenceFramesIsLittleEndian24Bytes() {
        // firstFrameIndex (LE), reserved, lastFrameIndex (LE), reserved[3]; 24 bytes total.
        let m = ControlMessage.invalidateReferenceFrames(first: 0x01020304, last: 0x0A0B0C0D)
        #expect(m.type == 0x0301)
        #expect(m.payload == [
            0x04, 0x03, 0x02, 0x01,   // firstFrameIndex (LE)
            0x00, 0x00, 0x00, 0x00,   // reserved1
            0x0D, 0x0C, 0x0B, 0x0A,   // lastFrameIndex (LE)
            0x00, 0x00, 0x00, 0x00,   // reserved2[0]
            0x00, 0x00, 0x00, 0x00,   // reserved2[1]
            0x00, 0x00, 0x00, 0x00,   // reserved2[2]
        ])
        #expect(m.payload.count == 24)
    }
}
