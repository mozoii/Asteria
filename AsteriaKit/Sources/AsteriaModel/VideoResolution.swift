/// Pixel dimensions of a video mode or display.
public struct PixelSize: Codable, Equatable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Target stream resolution: a fixed mode, the Mac display's mode, or a custom size.
public enum VideoResolution: Codable, Equatable, Sendable, Hashable {
    case preset(width: Int, height: Int)
    case matchDisplay
    case custom(width: Int, height: Int)

    public static let hd720 = VideoResolution.preset(width: 1280, height: 720)
    public static let hd1080 = VideoResolution.preset(width: 1920, height: 1080)
    public static let qhd1440 = VideoResolution.preset(width: 2560, height: 1440)
    public static let uhd4K = VideoResolution.preset(width: 3840, height: 2160)

    /// Custom mode with each dimension clamped to a sane minimum.
    public static func custom(clampingWidth w: Int, height h: Int) -> VideoResolution {
        .custom(width: max(1, w), height: max(1, h))
    }

    /// Concrete pixel size; `matchDisplay` needs the live display and yields nil when it is unknown.
    public func dimensions(matchingDisplay display: PixelSize?) -> PixelSize? {
        switch self {
        case let .preset(w, h), let .custom(w, h): return PixelSize(width: w, height: h)
        case .matchDisplay: return display
        }
    }
}
