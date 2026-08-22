import Foundation

/// Supported video formats (GameStream VIDEO_FORMAT_* bitfield).
public struct VideoFormat: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let h264           = VideoFormat(rawValue: 0x0001)
    public static let h264High8_444  = VideoFormat(rawValue: 0x0004)
    public static let hevc           = VideoFormat(rawValue: 0x0100)
    public static let hevcMain10     = VideoFormat(rawValue: 0x0200)
    public static let hevcRext8_444  = VideoFormat(rawValue: 0x0400)
    public static let hevcRext10_444 = VideoFormat(rawValue: 0x0800)
    public static let av1Main8       = VideoFormat(rawValue: 0x1000)
    public static let av1Main10      = VideoFormat(rawValue: 0x2000)
    public static let av1High8_444   = VideoFormat(rawValue: 0x4000)
    public static let av1High10_444  = VideoFormat(rawValue: 0x8000)

    public static let maskH264: VideoFormat = [.h264, .h264High8_444]
    public static let maskHevc: VideoFormat = [.hevc, .hevcMain10, .hevcRext8_444, .hevcRext10_444]
    public static let maskAv1:  VideoFormat = [.av1Main8, .av1Main10, .av1High8_444, .av1High10_444]
    public static let mask10Bit: VideoFormat = [.hevcMain10, .hevcRext10_444, .av1Main10, .av1High10_444]
    public static let mask444: VideoFormat = [.h264High8_444, .hevcRext8_444, .hevcRext10_444, .av1High8_444, .av1High10_444]

    /// True when the negotiated format carries 10-bit samples; governs 10-bit decode + present.
    public var isTenBit: Bool { !isDisjoint(with: .mask10Bit) }
}
