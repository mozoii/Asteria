import GameStreamProtocol

public extension NALCodec {
    /// Map `VideoFormat` to NAL codec (H.264/HEVC), or `nil` for AV1.
    init?(videoFormat: VideoFormat) {
        if VideoFormat.maskAv1.contains(videoFormat) { return nil }
        self = VideoFormat.maskH264.contains(videoFormat) ? .h264 : .hevc
    }
}
