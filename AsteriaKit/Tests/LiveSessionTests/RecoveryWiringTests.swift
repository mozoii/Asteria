import Testing
import GameStreamProtocol
import VideoEngine
@testable import LiveSession

@Suite("Recovery → control-message wiring")
struct RecoveryWiringTests {
    @Test("an IDR request maps to the request-IDR control message")
    func idrMapsToRequestIdr() {
        let m = LiveStreamRunner.controlMessage(for: .idr)
        #expect(m.type == ControlMessage.requestIdr.type)
        #expect(m.payload == ControlMessage.requestIdr.payload)
    }

    @Test("an RFI request maps to the reference-frame-invalidation message for the lost range")
    func rfiMapsToInvalidateReferenceFrames() {
        let m = LiveStreamRunner.controlMessage(for: .invalidateReferenceFrames(first: 12, last: 19))
        let expected = ControlMessage.invalidateReferenceFrames(first: 12, last: 19)
        #expect(m.type == expected.type)
        #expect(m.payload == expected.payload)
    }

    // RFI enabled only when host advertises in SDP AND codec supports it (HEVC/AV1); else full IDR.
    private static let sdpWithRFI =
        ["v=0", "t=0 0", "a=x-nv-video[0].refPicInvalidation:1"].joined(separator: "\r\n") + "\r\n"
    private static let sdpWithoutRFI =
        ["v=0", "t=0 0", "a=x-nv-video[0].clientViewportWd:1920"].joined(separator: "\r\n") + "\r\n"

    @Test("HEVC + host advertises RFI → enabled")
    func rfiEnabledForHEVC() {
        #expect(LiveStreamRunner.referenceInvalidationEnabled(serverSDP: Self.sdpWithRFI, videoFormat: .hevc))
    }

    @Test("HEVC but host does not advertise RFI → disabled")
    func rfiDisabledWhenHostSilent() {
        #expect(!LiveStreamRunner.referenceInvalidationEnabled(serverSDP: Self.sdpWithoutRFI, videoFormat: .hevc))
    }

    @Test("H.264 even with host advertising RFI → disabled (VT lacks AVC RFI)")
    func rfiDisabledForH264() {
        #expect(!LiveStreamRunner.referenceInvalidationEnabled(serverSDP: Self.sdpWithRFI, videoFormat: .h264))
    }
}
