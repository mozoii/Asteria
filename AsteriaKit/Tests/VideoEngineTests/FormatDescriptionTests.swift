import Testing
import CoreMedia
import VideoToolbox
@testable import VideoEngine

@Suite("CMVideoFormatDescription from parameter sets")
struct FormatDescriptionTests {
    @Test("H.264: rebuilt description matches dimensions and codec")
    func h264() throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: kCMVideoCodecType_H264, width: 128, height: 64)
        #expect(fixture.parameterSets.count >= 2)   // SPS + PPS — sanity-check the harness

        let format = try FormatDescriptionBuilder.make(codec: .h264, parameterSets: fixture.parameterSets)
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dims.width == 128)
        #expect(dims.height == 64)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
    }

    @Test("HEVC: rebuilt description matches dimensions and codec")
    func hevc() throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: kCMVideoCodecType_HEVC, width: 128, height: 64)
        #expect(fixture.parameterSets.count >= 3)   // VPS + SPS + PPS

        let format = try FormatDescriptionBuilder.make(codec: .hevc, parameterSets: fixture.parameterSets)
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dims.width == 128)
        #expect(dims.height == 64)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
    }

    @Test("empty parameter sets are rejected")
    func rejectsEmpty() {
        #expect(throws: VideoFormatError.parameterSetsMissing) {
            _ = try FormatDescriptionBuilder.make(codec: .h264, parameterSets: [])
        }
    }
}
