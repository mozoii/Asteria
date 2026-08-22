import GameStreamProtocol

/// Decode-submission protocol: feed frames, learn via `SubmitStatus` whether to request IDR. Allows actor conformers.
public protocol DecoderRenderer: Sendable {
    func submit(_ frame: AssembledFrame) async -> SubmitStatus
    func stop() async
}

extension VideoDecoder: DecoderRenderer {
    public func submit(_ frame: AssembledFrame) -> SubmitStatus {
        submit(annexB: frame.data, frameIndex: frame.frameIndex)
    }
}
