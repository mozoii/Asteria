import GameStreamProtocol
import VideoEngine
import Discovery
import AsteriaModel

/// Pick video format (Mac decode caps ∩ host offer, honoring user preference). Codec families
/// outside `StreamPlan.negotiableCodecs` are excluded; falls back to best NAL.
public enum CapabilityNegotiator {
    public static func negotiateVideoFormat(host: String, codec: CodecPreference = .auto,
                                            hdrDisplay: Bool = false,
                                            preferTenBit: Bool = false) async -> VideoFormat {
        var caps = DecoderCapabilities.probe(hdrDisplay: hdrDisplay)
        let excluded = CodecPreference.allCases.filter { !StreamPlan.negotiableCodecs.contains($0) }
        for codec in excluded {
            if let mask = codecMask(codec) { caps.disableFamilies(mask) }
        }
        let mask = codecMask(codec)

        if let info = try? await HostPoller.fetchServerInfo(host: host),
           let scm = info.serverCodecModeSupport,
           let negotiated = caps.negotiatedFormat(hostFormats: .fromServerCodecModeSupport(scm),
                                                  restrictedTo: mask, preferTenBit: preferTenBit) {
            return negotiated
        }
        return caps.negotiatedFormat(hostFormats: caps.supportedFormats(),
                                     restrictedTo: mask, preferTenBit: preferTenBit) ?? .h264
    }

    /// Map codec preference to VideoFormat family mask (nil for .auto).
    private static func codecMask(_ codec: CodecPreference) -> VideoFormat? {
        switch codec {
        case .auto: return nil
        case .h264: return .maskH264
        case .hevc: return .maskHevc
        case .av1: return .maskAv1
        }
    }
}
