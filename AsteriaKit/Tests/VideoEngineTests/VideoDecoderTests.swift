import Testing
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import VideoEngine

@Suite("VideoDecoder round-trip (synth fixtures)")
struct VideoDecoderTests {
    @Test("H.264 keyframe decodes to a CVPixelBuffer of the right size")
    func h264RoundTrip() async throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: kCMVideoCodecType_H264, width: 640, height: 480)
        let holder = LatestFrameHolder()
        let decoder = VideoDecoder(codec: .h264, holder: holder)

        let status = await decoder.submit(annexB: fixture.annexB, frameIndex: 7)
        #expect(status == .ok)
        await decoder.waitForFrames()

        let frame = holder.peek()
        #expect(frame != nil)
        #expect(frame?.frameIndex == 7)
        if let buffer = frame?.buffer {
            #expect(CVPixelBufferGetWidth(buffer) == 640)
            #expect(CVPixelBufferGetHeight(buffer) == 480)
            #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
        await decoder.stop()
    }

    @Test("HEVC keyframe decodes to a CVPixelBuffer")
    func hevcRoundTrip() async throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: kCMVideoCodecType_HEVC, width: 640, height: 480)
        let holder = LatestFrameHolder()
        let decoder = VideoDecoder(codec: .hevc, holder: holder)

        let status = await decoder.submit(annexB: fixture.annexB, frameIndex: 1)
        #expect(status == .ok)
        await decoder.waitForFrames()

        #expect(holder.peek() != nil)
        #expect(CVPixelBufferGetWidth(holder.peek()!.buffer) == 640)
        await decoder.stop()
    }

    @Test("output pixel format follows requested bit depth")
    func outputFormatSelection() {
        #expect(VideoDecoder.outputPixelFormat(tenBit: true) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(VideoDecoder.outputPixelFormat(tenBit: false) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test("a 10-bit HEVC keyframe decodes to a 10-bit CVPixelBuffer")
    func tenBitDecodeOutput() async throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: kCMVideoCodecType_HEVC,
                                                          width: 640, height: 480, tenBit: true)
        let holder = LatestFrameHolder()
        let decoder = VideoDecoder(codec: .hevc, holder: holder,
                                   outputPixelFormat: VideoDecoder.outputPixelFormat(tenBit: true))

        let status = await decoder.submit(annexB: fixture.annexB, frameIndex: 3)
        #expect(status == .ok)
        await decoder.waitForFrames()

        let buffer = try #require(holder.peek()?.buffer)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        await decoder.stop()
    }

    @Test("an 8-bit-configured decoder truncates a 10-bit stream to an 8-bit buffer")
    func tenBitStreamTruncatedWhenEightBit() async throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: kCMVideoCodecType_HEVC,
                                                          width: 640, height: 480, tenBit: true)
        let holder = LatestFrameHolder()
        let decoder = VideoDecoder(codec: .hevc, holder: holder,
                                   outputPixelFormat: VideoDecoder.outputPixelFormat(tenBit: false))

        #expect(await decoder.submit(annexB: fixture.annexB, frameIndex: 4) == .ok)
        await decoder.waitForFrames()

        let buffer = try #require(holder.peek()?.buffer)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        await decoder.stop()
    }

    @Test("a non-keyframe before any keyframe yields needsIdr, no frame")
    func needsIdrBeforeKeyframe() async throws {
        // A bare non-IDR slice (type 1), no parameter sets.
        let nonKeyframe: [UInt8] = [0, 0, 0, 1, 0x41, 0x9A, 0x00]
        let holder = LatestFrameHolder()
        let decoder = VideoDecoder(codec: .h264, holder: holder)

        let status = await decoder.submit(annexB: nonKeyframe, frameIndex: 1)
        #expect(status == .needsIdr)
        #expect(holder.peek() == nil)
        await decoder.stop()
    }
}
