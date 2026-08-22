import Testing
import QuartzCore
import Metal
import GameStreamProtocol
import VideoEngine

@Suite("Video presentation assembly")
struct VideoPresentationTests {
    private let size = CGSize(width: 1920, height: 1080)

    @Test("H.264 assembles an 8-bit present path with zeroed counters")
    func h264EightBit() {
        let p = VideoPresentation(videoFormat: .h264, initialSize: size,
                                  options: PresentOptions(streamFps: 60, displayMaxHz: 120, enableMetalFX: false))
        #expect(p != nil)
        #expect(p?.metalLayer.pixelFormat == .bgra8Unorm)
        #expect(p?.deliveredCount == 0)
        #expect(p?.presentedCount == 0)
    }

    @Test("a 10-bit HEVC format assembles a 10-bit present path")
    func hevc10Bit() {
        let p = VideoPresentation(videoFormat: .hevcMain10, initialSize: size,
                                  options: PresentOptions(streamFps: 60, displayMaxHz: nil, enableMetalFX: true))
        #expect(p?.metalLayer.pixelFormat == .bgr10a2Unorm)
    }

    @Test("AV1 has no NAL decode path, so presentation is unavailable")
    func av1Unavailable() {
        let p = VideoPresentation(videoFormat: .av1Main8, initialSize: size,
                                  options: PresentOptions(streamFps: 60, displayMaxHz: nil, enableMetalFX: false))
        #expect(p == nil)
    }
}
