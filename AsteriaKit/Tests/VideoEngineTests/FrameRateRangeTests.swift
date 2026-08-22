import Testing
import QuartzCore
@testable import VideoEngine

@Suite("Display-link frame-rate range")
struct FrameRateRangeTests {
    @Test("pins to the stream rate when the display has no real headroom")
    func pinsWhenEqual() {
        let r = MetalVideoPresenter.frameRateRange(streamFps: 240, displayMaxHz: 240)
        #expect(r.minimum == 240 && r.maximum == 240 && r.preferred == 240)
    }

    @Test("spans stream…displayMax, preferring the panel max, when the panel can refresh faster")
    func spansWithHeadroom() {
        let r = MetalVideoPresenter.frameRateRange(streamFps: 120, displayMaxHz: 240)
        #expect(r.minimum == 120 && r.maximum == 240 && r.preferred == 240)
    }

    @Test("a headroom within slack still pins to the stream rate")
    func withinSlackPins() {
        let r = MetalVideoPresenter.frameRateRange(streamFps: 240, displayMaxHz: 244)
        #expect(r.maximum == 240)
    }

    @Test("missing display rate pins to the stream rate")
    func nilDisplayPins() {
        let r = MetalVideoPresenter.frameRateRange(streamFps: 180, displayMaxHz: nil)
        #expect(r.minimum == 180 && r.maximum == 180 && r.preferred == 180)
    }
}
