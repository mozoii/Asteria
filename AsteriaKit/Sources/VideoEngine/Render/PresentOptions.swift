/// Present-path preferences that travel together from the video sink down to the Metal presenter:
/// frame pacing, upscaling, and dynamic range. Bit depth is derived from the negotiated format, not carried here.
public struct PresentOptions: Sendable {
    public let streamFps: Int
    public let displayMaxHz: Int?
    public let enableMetalFX: Bool
    public let hdr: Bool

    public init(streamFps: Int, displayMaxHz: Int?, enableMetalFX: Bool = true, hdr: Bool = false) {
        self.streamFps = streamFps
        self.displayMaxHz = displayMaxHz
        self.enableMetalFX = enableMetalFX
        self.hdr = hdr
    }
}
