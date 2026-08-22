import Testing
@testable import GameStreamProtocol

@Suite("Host control decoder (inbound)")
struct HostControlDecoderTests {
    @Test func rumbleSkipsReservedPrefix() {
        let payload: [UInt8] = [0, 0, 0, 0, 0x01, 0x00, 0x00, 0x80, 0x00, 0x40]
        #expect(HostControlDecoder.decode(type: 0x010b, payload: payload)
                == .rumble(controllerNumber: 1, lowFreq: 0x8000, highFreq: 0x4000))
    }

    @Test func rumbleTriggers() {
        let payload: [UInt8] = [0x02, 0x00, 0x34, 0x12, 0x78, 0x56]
        #expect(HostControlDecoder.decode(type: 0x5500, payload: payload)
                == .rumbleTriggers(controllerNumber: 2, leftTrigger: 0x1234, rightTrigger: 0x5678))
    }

    @Test func setMotionEventState() {
        let payload: [UInt8] = [0x00, 0x00, 0xC8, 0x00, 0x02]   // cn 0, 200 Hz, gyro
        #expect(HostControlDecoder.decode(type: 0x5501, payload: payload)
                == .setMotionEventState(controllerNumber: 0, reportRateHz: 200, motionType: 2))
    }

    @Test func setControllerLED() {
        let payload: [UInt8] = [0x01, 0x00, 0xFF, 0x80, 0x40]
        #expect(HostControlDecoder.decode(type: 0x5502, payload: payload)
                == .setControllerLED(controllerNumber: 1, red: 255, green: 128, blue: 64))
    }

    @Test func setAdaptiveTriggers() {
        let left = Array<UInt8>(1...10), right = Array<UInt8>(11...20)
        let payload: [UInt8] = [0x00, 0x00, 0x04, 0x26, 0x00] + left + right
        #expect(HostControlDecoder.decode(type: 0x5503, payload: payload)
                == .setAdaptiveTriggers(controllerNumber: 0, eventFlags: 0x04, typeLeft: 0x26,
                                        typeRight: 0x00, left: left, right: right))
    }

    @Test func hdrModeToggle() {
        #expect(HostControlDecoder.decode(type: 0x010e, payload: [0x01]) == .setHdrMode(enabled: true))
        #expect(HostControlDecoder.decode(type: 0x010e, payload: [0x00]) == .setHdrMode(enabled: false))
    }

    @Test func terminationErrorCodeIsBigEndian() {
        #expect(HostControlDecoder.decode(type: 0x0109, payload: [0x80, 0x03, 0x00, 0x23])
                == .termination(errorCode: 0x8003_0023))
    }

    @Test func unknownTypeAndTruncatedPayloadsFallBack() {
        #expect(HostControlDecoder.decode(type: 0x9999, payload: [1, 2, 3]) == .unknown(type: 0x9999, payload: [1, 2, 3]))
        #expect(HostControlDecoder.decode(type: 0x010b, payload: [0, 0]) == .unknown(type: 0x010b, payload: [0, 0]))
    }

    @Test func cryptoRoundTripThroughOpenAndDecode() throws {
        let rikey = Array<UInt8>(0..<16)
        let crypto = ControlCrypto(rikey: rikey)
        let ledPayload: [UInt8] = [0x03, 0x00, 0x11, 0x22, 0x33]   // cn 3, rgb 0x11/0x22/0x33
        let wire = try crypto.seal(type: 0x5502, payload: ledPayload, seq: 7, origin: .host)

        let (type, payload) = try crypto.open(wire, origin: .host)
        #expect(HostControlDecoder.decode(type: type, payload: payload)
                == .setControllerLED(controllerNumber: 3, red: 0x11, green: 0x22, blue: 0x33))
    }
}
