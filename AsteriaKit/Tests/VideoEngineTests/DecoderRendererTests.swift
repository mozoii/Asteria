import Testing
import CoreMedia
import CoreVideo
import GameStreamProtocol
@testable import VideoEngine

@Suite("DecoderRenderer seam")
struct DecoderRendererTests {
    @Test("submits an AssembledFrame through the protocol and decodes it")
    func submitsAssembledFrame() async throws {
        let fixture = try SyntheticEncoder.encodeKeyframe(codec: kCMVideoCodecType_H264, width: 640, height: 480)
        let holder = LatestFrameHolder()
        let decoder = VideoDecoder(codec: .h264, holder: holder)
        let renderer: any DecoderRenderer = decoder

        let frame = AssembledFrame(frameIndex: 42, data: fixture.annexB, recovered: false)
        let status = await renderer.submit(frame)
        #expect(status == .ok)

        await decoder.waitForFrames()
        #expect(holder.peek()?.frameIndex == 42)
        await renderer.stop()
    }
}
