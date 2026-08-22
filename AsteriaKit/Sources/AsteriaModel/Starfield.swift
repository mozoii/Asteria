import Foundation

/// Palette slot for a background star; the view maps it to a concrete color.
public enum StarTint: Sendable, Equatable {
    case accent, blueWhite, white
}

/// One star's fixed layout: normalized home position, point size, drift speed, twinkle, tint.
public struct StarLayout: Sendable, Equatable {
    public var x, y, size, baseAlpha, speed, twinklePhase: Double
    public var twinkle: Bool
    public var tint: StarTint
}

/// A momentary shooting star: normalized head/tail endpoints and stroke alpha.
public struct ShootingStar: Sendable, Equatable {
    public var headX, headY, tailX, tailY, alpha: Double
}

/// Deterministic onboarding starfield: a fixed field of drifting, twinkling stars plus a periodic
/// shooting star, reproducible from fixed seeds so the field is identical every launch and in tests.
public struct Starfield: Sendable {
    /// Accent-bloom center in normalized space; accent stars cluster near it.
    public static let bloomCenter = (x: 0.5, y: 0.40)

    public let stars: [StarLayout]

    public init(intensity: Double = 1) {
        var g = SeededGenerator(seed: 0xA5731F2C)
        let count = max(8, Int(54 * intensity))
        var result: [StarLayout] = []
        for _ in 0 ..< count {
            let x = Double.random(in: 0 ... 1, using: &g)
            let y = Double.random(in: 0 ... 1, using: &g)
            let depth = Double.random(in: 0 ... 1, using: &g)              // 0 far → 1 near
            let size = 0.7 + depth * depth * 2.0                           // 0.7…2.7 pt
            var alpha = (0.12 + depth * 0.55) * (0.6 + 0.4 * intensity)
            let speed = 0.006 + depth * 0.008                              // ~71…166s to cross
            let twinkle = depth > 0.7 && Double.random(in: 0 ... 1, using: &g) < 0.5
            let twinklePhase = Double.random(in: 0 ..< (2 * .pi), using: &g)
            let dx = x - Self.bloomCenter.x, dy = y - Self.bloomCenter.y
            let nearBloom = (dx * dx + dy * dy).squareRoot() < 0.28
            let accent = nearBloom && Double.random(in: 0 ... 1, using: &g) < 0.3
            let tint: StarTint
            if accent {
                tint = .accent
                alpha *= 0.6                                               // embers stay dim
            } else if Double.random(in: 0 ... 1, using: &g) < 0.4 {
                tint = .blueWhite
            } else {
                tint = .white
            }
            result.append(StarLayout(x: x, y: y, size: size, baseAlpha: min(alpha, 0.85),
                                     speed: speed, twinklePhase: twinklePhase, twinkle: twinkle, tint: tint))
        }
        self.stars = result
    }

    /// Drifted, wrapped normalized position of a star at time `t` (seconds); parallax via per-star speed.
    public func position(of star: StarLayout, at t: Double) -> (x: Double, y: Double) {
        let dirX = 0.95, dirY = -0.31      // gentle drift up-and-right
        return (Self.wrap01(star.x + dirX * star.speed * t),
                Self.wrap01(star.y + dirY * star.speed * t))
    }

    /// Rendered alpha of a star at time `t`; twinkling stars breathe when `animate` is on.
    public func alpha(of star: StarLayout, at t: Double, animate: Bool) -> Double {
        guard animate && star.twinkle else { return star.baseAlpha }
        return star.baseAlpha * (0.55 + 0.45 * sin(t * 0.8 + star.twinklePhase))
    }

    /// The shooting star crossing at time `t`, or nil between appearances (one per ~34s period).
    public static func shootingStar(at t: Double) -> ShootingStar? {
        let period = 34.0
        let n = (t / period).rounded(.down)
        var g = SeededGenerator(seed: UInt64(bitPattern: Int64(n) &* 2654435761) ^ 0x9E3779B1)
        let jitter = Double.random(in: 0 ..< (period - 1.5), using: &g)
        let start = n * period + jitter
        let p = (t - start) / 0.95
        guard p >= 0, p <= 1 else { return nil }
        let sx = Double.random(in: 0.08 ... 0.75, using: &g)
        let sy = Double.random(in: 0.05 ... 0.45, using: &g)
        let angle = Double.random(in: 0.35 ... 0.62, using: &g)    // radians, down-and-right
        let travel = 0.45, tailLen = 0.07
        let dx = cos(angle), dy = sin(angle)
        let hx = sx + dx * p * travel, hy = sy + dy * p * travel
        return ShootingStar(headX: hx, headY: hy,
                            tailX: hx - dx * tailLen, tailY: hy - dy * tailLen,
                            alpha: 0.5 * sin(.pi * p))
    }

    /// Wraps a normalized coordinate back into 0..<1 so drifting stars recycle across the canvas.
    public static func wrap01(_ v: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: 1)
        return r < 0 ? r + 1 : r
    }
}

/// Deterministic SplitMix64 so generated fields are identical every launch (and stable in previews/tests).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
