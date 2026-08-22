/// Target frame rate: a fixed value or the Mac display's refresh.
public enum FrameRate: Codable, Equatable, Sendable, Hashable {
    case fps(Int)
    case matchDisplay

    public static let fps30 = FrameRate.fps(30)
    public static let fps60 = FrameRate.fps(60)
    public static let fps120 = FrameRate.fps(120)
    public static let fps240 = FrameRate.fps(240)

    /// Fixed rate clamped to a sane minimum.
    public static func fps(clamping v: Int) -> FrameRate { .fps(max(1, v)) }

    /// Concrete rate; `matchDisplay` needs the live display and yields nil when it is unknown.
    public func value(matchingDisplay display: Int?) -> Int? {
        switch self {
        case let .fps(v): return v
        case .matchDisplay: return display
        }
    }
}
