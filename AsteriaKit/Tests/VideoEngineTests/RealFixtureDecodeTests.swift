import Testing
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import VideoEngine

/// Real Sunshine keyframe hardware-decode validation; synthetic + real = comprehensive decode coverage.
@Suite("Real Sunshine fixture decode")
struct RealFixtureDecodeTests {
    static func loadFixture() throws -> [UInt8] {
        let url = try #require(
            Bundle.module.url(forResource: "sunshine-hevc-keyframe", withExtension: "bin", subdirectory: "Fixtures"))
        return Array(try Data(contentsOf: url))
    }

    @Test("the captured frame is a complete HEVC keyframe (VPS+SPS+PPS+IDR)")
    func fixtureIsKeyframe() throws {
        let annexB = try Self.loadFixture()
        let split = AccessUnit.split(annexB, codec: .hevc)
        #expect(split.isKeyframe)
        #expect(split.parameterSets.count == 3)
        #expect(!split.sampleNALs.isEmpty)
    }

    @Test("a real Sunshine HEVC keyframe hardware-decodes to a 1080p CVPixelBuffer")
    func realKeyframeDecodes() async throws {
        let annexB = try Self.loadFixture()
        let holder = LatestFrameHolder()
        let decoder = VideoDecoder(codec: .hevc, holder: holder)

        let status = await decoder.submit(annexB: annexB, frameIndex: 42)
        #expect(status == .ok)
        await decoder.waitForFrames()

        let frame = holder.peek()
        #expect(frame != nil)
        #expect(frame?.frameIndex == 42)
        if let buffer = frame?.buffer {
            #expect(CVPixelBufferGetWidth(buffer) == 1920)
            #expect(CVPixelBufferGetHeight(buffer) == 1080)
        }
        await decoder.stop()
    }
}
