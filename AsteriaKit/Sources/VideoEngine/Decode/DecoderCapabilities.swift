import CoreMedia
import VideoToolbox
import GameStreamProtocol

/// Hardware decode capabilities gating `StreamConfiguration` requests. AV1 needs M3+; HDR needs 10-bit + EDR display.
public struct DecoderCapabilities: Sendable, Equatable {
    public var h264: Bool
    public var hevc: Bool
    public var hevcMain10: Bool
    public var av1: Bool
    public var av1Main10: Bool
    public var hevc444: Bool
    public var av1444: Bool
    public var hdrDisplay: Bool

    public init(h264: Bool = false, hevc: Bool = false, hevcMain10: Bool = false,
                av1: Bool = false, av1Main10: Bool = false,
                hevc444: Bool = false, av1444: Bool = false, hdrDisplay: Bool = false) {
        self.h264 = h264
        self.hevc = hevc
        self.hevcMain10 = hevcMain10
        self.av1 = av1
        self.av1Main10 = av1Main10
        self.hevc444 = hevc444
        self.av1444 = av1444
        self.hdrDisplay = hdrDisplay
    }

    /// HDR needs an EDR display and HEVC Main10 decode — the present path has no AV1 decoder, so AV1 can't carry it.
    public var supportsHDR: Bool { hdrDisplay && hevcMain10 }

    /// Every `VideoFormat` this machine can hardware-decode. Intersected with host offer.
    public func supportedFormats() -> VideoFormat {
        var formats: VideoFormat = []
        if h264 { formats.insert(.h264) }
        if hevc { formats.insert(.hevc) }
        if hevcMain10 { formats.insert(.hevcMain10) }
        if av1 { formats.insert(.av1Main8) }
        if av1Main10 { formats.insert(.av1Main10) }
        if hevc444 {
            formats.insert(.hevcRext8_444)
            if hevcMain10 { formats.insert(.hevcRext10_444) }
        }
        if av1444 {
            formats.insert(.av1High8_444)
            if av1Main10 { formats.insert(.av1High10_444) }
        }
        return formats
    }

    /// Best base format: AV1 → HEVC → H.264; 10-bit when the display is HDR or the user prefers 10-bit SDR.
    public func preferredFormat(preferTenBit: Bool = false) -> VideoFormat? {
        let tenBit = hdrDisplay || preferTenBit
        if av1 { return (av1Main10 && tenBit) ? .av1Main10 : .av1Main8 }
        if hevc { return (hevcMain10 && tenBit) ? .hevcMain10 : .hevc }
        if h264 { return .h264 }
        return nil
    }

    /// Negotiate format: intersect host ∩ machine, prefer newest codec (AV1 → HEVC → H.264) and richest profile.
    /// 10-bit is preferred when the display is HDR or `preferTenBit` is set (10-bit SDR).
    public func negotiatedFormat(hostFormats: VideoFormat, preferTenBit: Bool = false) -> VideoFormat? {
        let common = supportedFormats().intersection(hostFormats)
        return preferenceOrder(tenBit: hdrDisplay || preferTenBit).first { common.contains($0) }
    }

    /// Negotiate honoring a codec restriction (a `VideoFormat` codec mask); when the restriction can't be met,
    /// fall back to the unrestricted pick so a stale or unsupported preference never blocks the stream.
    public func negotiatedFormat(hostFormats: VideoFormat, restrictedTo mask: VideoFormat?,
                                 preferTenBit: Bool = false) -> VideoFormat? {
        let unrestricted = negotiatedFormat(hostFormats: hostFormats, preferTenBit: preferTenBit)
        guard let mask else { return unrestricted }
        let common = supportedFormats().intersection(hostFormats).intersection(mask)
        let pick = preferenceOrder(tenBit: hdrDisplay || preferTenBit).first { common.contains($0) }
        return pick ?? unrestricted
    }

    /// Negotiate against raw `serverCodecModeSupport` bitfield.
    public func negotiatedFormat(serverCodecModeSupport scm: Int, preferTenBit: Bool = false) -> VideoFormat? {
        negotiatedFormat(hostFormats: .fromServerCodecModeSupport(scm), preferTenBit: preferTenBit)
    }

    /// Preference ladder: 4:4:4 over 4:2:0, 10-bit over 8-bit when `tenBit`. Inert entries don't affect `supportedFormats()`.
    private func preferenceOrder(tenBit: Bool) -> [VideoFormat] {
        func codec(_ rext10: VideoFormat, _ main10: VideoFormat,
                   _ rext8: VideoFormat, _ main8: VideoFormat) -> [VideoFormat] {
            tenBit ? [rext10, main10, rext8, main8] : [rext8, main8, rext10, main10]
        }
        return codec(.av1High10_444, .av1Main10, .av1High8_444, .av1Main8)
             + codec(.hevcRext10_444, .hevcMain10, .hevcRext8_444, .hevc)
             + [.h264High8_444, .h264]
    }

    /// VideoToolbox RFI support (cheaper than IDR). Supported for HEVC and AV1, not H.264.
    public static func supportsReferenceFrameInvalidation(for format: VideoFormat) -> Bool {
        !format.isDisjoint(with: .maskHevc) || !format.isDisjoint(with: .maskAv1)
    }

    /// Drop every format family present in `formats` — used to apply the product codec policy
    /// (`StreamPlan.negotiableCodecs`) to a probed decoder.
    public mutating func disableFamilies(_ formats: VideoFormat) {
        if !formats.isDisjoint(with: .maskH264) { h264 = false }
        if !formats.isDisjoint(with: .maskHevc) { hevc = false; hevcMain10 = false }
        if !formats.isDisjoint(with: .maskAv1) { av1 = false; av1Main10 = false }
    }

    /// Probe VideoToolbox decoders. Apple Silicon: HEVC/AV1 HW implies Main10. 4:4:4 gated conservatively.
    public static func probe(hdrDisplay: Bool) -> DecoderCapabilities {
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        return DecoderCapabilities(
            h264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
            hevc: hevc,
            hevcMain10: hevc,
            av1: av1,
            av1Main10: av1,
            hevc444: false,
            av1444: false,
            hdrDisplay: hdrDisplay)
    }
}
