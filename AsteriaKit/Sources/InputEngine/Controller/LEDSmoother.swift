/// Low-pass + hysteresis filter for the host's high-rate LED stream: reconstructs a PWM-toggled channel as a steady color.
struct LEDSmoother {
    private var level: SIMD3<Float> = .zero
    private var written: (r: Int, g: Int, b: Int)?
    private let alpha: Float
    private let threshold: Int

    init(alpha: Float = 0.05, threshold: Int = 10) {
        self.alpha = alpha
        self.threshold = threshold
    }

    mutating func feed(red: UInt8, green: UInt8, blue: UInt8) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        level += alpha * (SIMD3(Float(red), Float(green), Float(blue)) - level)
        let r = Int(level.x.rounded()), g = Int(level.y.rounded()), b = Int(level.z.rounded())
        if let w = written, abs(r - w.r) < threshold, abs(g - w.g) < threshold, abs(b - w.b) < threshold {
            return nil
        }
        written = (r, g, b)
        return (UInt8(r), UInt8(g), UInt8(b))
    }
}
