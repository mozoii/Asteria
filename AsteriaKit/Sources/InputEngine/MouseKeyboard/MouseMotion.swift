/// Accumulates fractional mouse deltas to whole pixels, carrying the sub-pixel remainder.
public struct MouseMotionAccumulator: Sendable {
    private var accumX = 0.0
    private var accumY = 0.0
    public init() {}

    public mutating func consume(deltaX: Double, deltaY: Double) -> (dx: Int, dy: Int) {
        accumX += deltaX
        accumY += deltaY
        let dx = Int(accumX)
        let dy = Int(accumY)
        accumX -= Double(dx)
        accumY -= Double(dy)
        return (dx, dy)
    }

    public mutating func reset() { accumX = 0; accumY = 0 }
}

public enum MouseScroll {
    public static let wheelDelta = 120.0

    public static func amount(precise: Double, reverse: Bool = false) -> Int16 {
        var v = reverse ? -precise : precise
        v = max(-1.0, min(1.0, v))
        return Int16(v * wheelDelta)
    }
}

public extension MouseRoute {
    static func resolve(absoluteMode: Bool) -> MouseRoute { absoluteMode ? .absolute : .relative }

    /// AppKit positions are for Desktop; Game uses raw GCMouse deltas.
    static func shouldForwardAppKitPointer(inputActive: Bool, absoluteMode: Bool) -> Bool {
        inputActive && absoluteMode
    }
}
