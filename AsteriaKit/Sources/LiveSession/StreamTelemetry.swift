import Foundation
import AudioEngine
import GameStreamProtocol
import InputEngine
import VideoEngine

/// One coherent session health sample: live counters (transport, decode, input, control) + negotiated facts (RFI, RTSP, SDP).
public struct StreamTelemetry: Sendable, Equatable, CustomStringConvertible {
    public var videoTransport: RTPStreamReceiver<AssembledFrame>.Stats
    public var audioTransport: RTPStreamReceiver<AudioOpusPacket>.Stats
    /// Decode outcomes + recovery accounting (post-reassembly).
    public var decode: VideoStats
    public var videoFrameLoss: VideoFrameAssembler.LossStats
    public var audio: AudioStats
    public var input: InputStats
    public var control: InboundControlCounts
    /// ENet control-channel mean RTT (ms); 0 before first acknowledgement.
    public var controlRoundTripMillis: UInt32
    /// Whether loss recovery uses reference-frame invalidation (vs. full IDR).
    public var referenceInvalidationEnabled: Bool
    public var rtspSession: RTSPSessionResult?
    public var lastSDP: String?

    public init(videoTransport: RTPStreamReceiver<AssembledFrame>.Stats = .init(),
                audioTransport: RTPStreamReceiver<AudioOpusPacket>.Stats = .init(),
                decode: VideoStats = .init(),
                videoFrameLoss: VideoFrameAssembler.LossStats = .init(),
                audio: AudioStats = .init(),
                input: InputStats = .init(),
                control: InboundControlCounts = .init(),
                controlRoundTripMillis: UInt32 = 0,
                referenceInvalidationEnabled: Bool = false,
                rtspSession: RTSPSessionResult? = nil,
                lastSDP: String? = nil) {
        self.videoTransport = videoTransport
        self.audioTransport = audioTransport
        self.decode = decode
        self.videoFrameLoss = videoFrameLoss
        self.audio = audio
        self.input = input
        self.control = control
        self.controlRoundTripMillis = controlRoundTripMillis
        self.referenceInvalidationEnabled = referenceInvalidationEnabled
        self.rtspSession = rtspSession
        self.lastSDP = lastSDP
    }

    public var description: String {
        "video \(videoTransport.outputs)f/\(videoTransport.recovered)rec/\(videoFrameLoss.lost)lost · "
            + "audio \(audioTransport.outputs)pkt/\(audio.packetsDecoded)dec/\(audio.concealed)plc/"
            + "\(audio.render.underruns)ur/\(audio.render.overruns)or · "
            + "decode \(decode.delivered)(" + String(format: "%.1f%%", decode.lossRate * 100) + " loss) · "
            + "input \(input.packetsSent)pkts/" + String(format: "%.0f%%", input.coalesceRatio * 100) + " coalesced · "
            + "control \(control.total)" + (referenceInvalidationEnabled ? " · RFI" : "")
    }
}
