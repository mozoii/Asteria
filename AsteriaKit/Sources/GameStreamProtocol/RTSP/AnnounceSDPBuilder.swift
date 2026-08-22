import Foundation

/// Builds the client's RTSP `ANNOUNCE` SDP: the minimum attribute set Sunshine-derived hosts require
/// (400 BAD REQUEST otherwise). Attribute ordering is Asteria's own; per-attribute provenance lives in docs/protocol-provenance.md.
public enum AnnounceSDPBuilder {
    /// RTSP client version token, also sent as `X-GS-ClientVersion` on every request.
    private static let clientVersion = "14"

    /// The requested maximum rate leaves FEC headroom so total wire rate stays inside the configured budget;
    /// the host computes the actual encode rate from `configuredBitrateKbps`.
    private static let fecHeadroomPercent = 80
    /// Practical ceiling for the requested maximum rate on reliable local links.
    private static let maxAdjustedBitrateKbps = 100_000

    public static func announce(for config: StreamConfiguration, host: String, videoServerPort: Int = 47998) -> String {
        let adjustedBitrate = min(config.bitrateKbps * Self.fecHeadroomPercent / 100, Self.maxAdjustedBitrateKbps)
        let is444 = !config.videoFormat.isDisjoint(with: .mask444)
        let isAV1 = !config.videoFormat.isDisjoint(with: .maskAv1)
        let isHEVC = !config.videoFormat.isDisjoint(with: .maskHevc)
        let channels = config.audio.channelCount

        var attributes: [String] = []

        // Session: encrypted control protocol and feature opt-ins. The host defaults these to
        // off/older values, so each must be sent to select the negotiated behavior.
        attributes += Self.attributeLines([
            ("x-ss-general.encryptionEnabled", "1"),
            ("x-ml-general.featureFlags", "3"),
            ("x-nv-general.useReliableUdp", "13"),
        ])

        // Video: stream geometry, decode constraints, and pacing hints. The host rejects the
        // request if the geometry or decode constraints are absent.
        var video: [(String, String)] = []
        if is444 {
            video.append(("x-ss-video[0].chromaSamplingType", "1"))
        }
        video += [
            ("x-nv-video[0].clientViewportWd", "\(config.width)"),
            ("x-nv-video[0].clientViewportHt", "\(config.height)"),
            ("x-nv-video[0].maxFPS", "\(config.fps)"),
            ("x-nv-video[0].clientRefreshRateX100", "\(config.fps * 100)"),
            ("x-nv-video[0].packetSize", "\(config.packetSize)"),
            ("x-nv-video[0].videoEncoderSlicesPerFrame", "1"),
            ("x-nv-video[0].maxNumReferenceFrames", "1"),
        ]
        if config.hdr {
            video.append(("x-nv-video[0].dynamicRangeMode", "1"))
        }
        attributes += Self.attributeLines(video)

        // Codec: the bitstream format the client can decode. The host defaults to H.264 when
        // the attribute is absent, so it is sent only for HEVC and AV1.
        var codec: [(String, String)] = []
        if isAV1 {
            codec.append(("x-nv-vqos[0].bitStreamFormat", "2"))
        } else if isHEVC {
            codec.append(("x-nv-vqos[0].bitStreamFormat", "1"))
        }
        attributes += Self.attributeLines(codec)

        // Bandwidth and QoS: the rate ceiling and FEC floor the host must honor, plus the
        // configured rate the host uses to compute the actual encode rate.
        attributes += Self.attributeLines([
            ("x-nv-vqos[0].bw.maximumBitrateKbps", "\(adjustedBitrate)"),
            ("x-nv-vqos[0].fec.minRequiredFecPackets", "2"),
            ("x-ml-video.configuredBitrateKbps", "\(config.bitrateKbps)"),
        ])

        // Audio: the channel layout and quality level the host must produce.
        attributes += Self.attributeLines([
            ("x-nv-audio.surround.numChannels", "\(channels)"),
            ("x-nv-audio.surround.channelMask", "\(config.audio.channelMask)"),
            ("x-nv-audio.surround.AudioQuality", "0"),
        ])

        var sdp = "v=0\r\n"
        sdp += "o=- 0 \(Self.clientVersion) IN IPv4 \(host)\r\n"
        sdp += "s=Asteria Streaming Client\r\n"
        sdp += attributes.joined(separator: "\r\n")
        sdp += "\r\n"
        sdp += "t=0 0\r\n"
        sdp += "m=video \(videoServerPort)\r\n"
        return sdp
    }

    private static func attributeLines(_ attributes: [(String, String)]) -> [String] {
        attributes.map { "a=\($0.0):\($0.1)" }
    }
}
