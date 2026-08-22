import Foundation

public extension VideoFormat {
    private enum ServerCodecMode {
        static let h264          = 0x00000001
        static let hevc          = 0x00000100
        static let hevcMain10    = 0x00000200
        static let av1Main8      = 0x00010000
        static let av1Main10     = 0x00020000
        static let h264High8_444 = 0x00040000
        static let hevcRext8_444 = 0x00080000
        static let hevcRext10_444 = 0x00100000
        static let av1High8_444  = 0x00200000
        static let av1High10_444 = 0x00400000
    }

    static func fromServerCodecModeSupport(_ scm: Int) -> VideoFormat {
        var formats: VideoFormat = []
        let map: [(Int, VideoFormat)] = [
            (ServerCodecMode.h264, .h264),
            (ServerCodecMode.hevc, .hevc),
            (ServerCodecMode.hevcMain10, .hevcMain10),
            (ServerCodecMode.av1Main8, .av1Main8),
            (ServerCodecMode.av1Main10, .av1Main10),
            (ServerCodecMode.h264High8_444, .h264High8_444),
            (ServerCodecMode.hevcRext8_444, .hevcRext8_444),
            (ServerCodecMode.hevcRext10_444, .hevcRext10_444),
            (ServerCodecMode.av1High8_444, .av1High8_444),
            (ServerCodecMode.av1High10_444, .av1High10_444),
        ]
        for (bit, format) in map where scm & bit != 0 { formats.insert(format) }
        return formats
    }
}
