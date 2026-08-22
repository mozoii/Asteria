import Testing
import CoreMedia
@testable import VideoEngine

@Suite("SampleBufferBuilder")
struct SampleBufferBuilderTests {
    @Test("builds a CMSampleBuffer from a synth keyframe, tracking the format")
    func buildsKeyframe() throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: kCMVideoCodecType_H264, width: 640, height: 480)
        let builder = SampleBufferBuilder(codec: .h264)

        guard case .built(let output) = builder.build(annexB: fixture.annexB) else {
            Issue.record("expected .built"); return
        }
        #expect(output.isKeyframe)
        #expect(output.formatChanged)
        let format = try #require(CMSampleBufferGetFormatDescription(output.sampleBuffer))
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dims.width == 640)
        #expect(dims.height == 480)
        #expect(builder.formatDescription != nil)
    }

    @Test("a second keyframe with identical parameter sets does not report a format change")
    func stableFormatAcrossKeyframes() throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: kCMVideoCodecType_H264, width: 640, height: 480)
        let builder = SampleBufferBuilder(codec: .h264)
        _ = builder.build(annexB: fixture.annexB)

        guard case .built(let output) = builder.build(annexB: fixture.annexB) else {
            Issue.record("expected .built"); return
        }
        #expect(!output.formatChanged)
    }

    @Test("a non-keyframe before any keyframe needs a keyframe")
    func needsKeyframe() {
        let builder = SampleBufferBuilder(codec: .h264)
        let nonKeyframe: [UInt8] = [0, 0, 0, 1, 0x41, 0x9A, 0x00]
        #expect(builder.build(annexB: nonKeyframe) == .needsKeyframe)
    }

    // Sunshine f0003 header: phantom NAL start code (00 00 01) that must be stripped end-to-end.
    private let phantomHeader: [UInt8] = [0x01, 0x00, 0x00, 0x01, 0xf9, 0x01, 0x00, 0x00]

    @Test("strips the Sunshine phantom-NAL header end-to-end through build",
          arguments: [(NALCodec.h264, kCMVideoCodecType_H264),
                      (NALCodec.hevc, kCMVideoCodecType_HEVC)])
    func stripsPhantomHeaderThroughBuild(codec: NALCodec, cmCodec: CMVideoCodecType) throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: cmCodec, width: 640, height: 480)

        guard case .built(let clean) = SampleBufferBuilder(codec: codec).build(annexB: fixture.annexB) else {
            Issue.record("expected .built for the clean fixture"); return
        }
        guard case .built(let withHeader) =
            SampleBufferBuilder(codec: codec).build(annexB: phantomHeader + fixture.annexB) else {
            Issue.record("expected .built through the phantom header"); return
        }

        #expect(withHeader.isKeyframe)
        #expect(withHeader.formatChanged)
        let dims = CMVideoFormatDescriptionGetDimensions(
            try #require(CMSampleBufferGetFormatDescription(withHeader.sampleBuffer)))
        #expect(dims.width == 640)
        #expect(dims.height == 480)
        // Phantom header fully stripped; sample size matches clean build.
        #expect(CMSampleBufferGetTotalSampleSize(withHeader.sampleBuffer)
                == CMSampleBufferGetTotalSampleSize(clean.sampleBuffer))
    }

    @Test("a phantom-header non-keyframe strips to the same sample as the clean slice")
    func stripsPhantomHeaderOnNonKeyframe() throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: kCMVideoCodecType_H264, width: 640, height: 480)
        let nonKeyframeAU: [UInt8] = [0, 0, 0, 1, 0x41, 0x9A, 0x12, 0x34]   // H.264 non-IDR slice (type 1)

        let cleanBuilder = SampleBufferBuilder(codec: .h264)
        _ = cleanBuilder.build(annexB: fixture.annexB)
        let headerBuilder = SampleBufferBuilder(codec: .h264)
        _ = headerBuilder.build(annexB: fixture.annexB)

        guard case .built(let clean) = cleanBuilder.build(annexB: nonKeyframeAU),
              case .built(let withHeader) = headerBuilder.build(annexB: phantomHeader + nonKeyframeAU) else {
            Issue.record("expected both non-keyframe builds to succeed"); return
        }
        #expect(!withHeader.isKeyframe)
        #expect(CMSampleBufferGetTotalSampleSize(withHeader.sampleBuffer)
                == CMSampleBufferGetTotalSampleSize(clean.sampleBuffer))
    }
}
