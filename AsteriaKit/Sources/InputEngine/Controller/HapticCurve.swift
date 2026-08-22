import Foundation

/// Maps host motor values to CoreHaptics intensities, linearly. The host already applied the game's
/// curve; re-curving here double-applies and muddies the range.
enum HapticCurve {
    /// Minimum intensity for non-zero input. 0 = passthrough; raise if weak rumble is too faint.
    static let floor: Float = 0

    /// Map a normalized 0…1 amplitude to intensity, lifting any non-zero value to at least `floor`.
    static func intensity(_ normalized: Float) -> Float {
        let v = max(0, min(1, normalized))
        if v <= 0 { return 0 }
        return floor + (1 - floor) * v
    }

    static func motorIntensity(_ motor: UInt16) -> Float { intensity(Float(motor) / 65535) }

    /// Combined channel for controllers without split handles: the louder motor sets the amplitude.
    static func combinedIntensity(low: UInt16, high: UInt16) -> Float {
        motorIntensity(max(low, high))
    }
}
