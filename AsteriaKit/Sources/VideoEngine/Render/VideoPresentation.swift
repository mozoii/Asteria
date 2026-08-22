import QuartzCore
import GameStreamProtocol

/// On-screen video presentation: assembles the decode → present path for a negotiated codec and geometry
/// behind a small interface — a Metal layer to host, a decoder renderer to feed, and live counters. Hides
/// the NAL codec, frame holder, hardware decoder, and Metal presenter. Returns nil for formats with no NAL
/// decode path (AV1).
public final class VideoPresentation {
    public let metalLayer: CAMetalLayer
    public let decoderRenderer: DecoderRenderer

    private let holder: LatestFrameHolder
    private let presenter: MetalVideoPresenter

    public init?(videoFormat: VideoFormat, initialSize: CGSize, options: PresentOptions) {
        guard let codec = NALCodec(videoFormat: videoFormat) else { return nil }   // AV1: no NAL path
        let tenBit = videoFormat.isTenBit
        let holder = LatestFrameHolder()
        guard let presenter = try? MetalVideoPresenter(holder: holder, initialSize: initialSize,
                                                       options: options, tenBit: tenBit)
        else { return nil }
        self.holder = holder
        self.presenter = presenter
        self.metalLayer = presenter.metalLayer
        self.decoderRenderer = VideoDecoder(codec: codec, holder: holder,
                                            outputPixelFormat: VideoDecoder.outputPixelFormat(tenBit: tenBit))
    }

    /// Follow the host's live HDR mode; the presenter refuses it on an SDR (non-10-bit) stream.
    public func setHDRActive(_ enabled: Bool) { presenter.setHDRActive(enabled) }

    /// Begin presenting decoded frames on the display link's dedicated render thread.
    public func start() { presenter.start() }

    /// Stop the present thread; the decoder renderer is torn down by the stream lifecycle that drives it.
    public func stop() { presenter.stop() }

    /// Frames the decoder has delivered to the presenter.
    public var deliveredCount: Int { holder.deliveredCount() }

    /// Frames the presenter has flipped to the display.
    public var presentedCount: Int { presenter.presentedCount }

    /// Rolling mean decode latency, in milliseconds.
    public var meanDecodeMillis: Double { holder.meanDecodeMillis() }
}
