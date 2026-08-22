import Testing
import Foundation
@testable import InputEngine

@Suite("Haptic curve")
struct HapticCurveTests {
    private func approx(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-4 }

    @Test func intensityIsLinearAndClamps() {
        #expect(HapticCurve.intensity(0) == 0)
        #expect(HapticCurve.intensity(-1) == 0)
        #expect(approx(HapticCurve.intensity(1), 1))
        #expect(approx(HapticCurve.intensity(2), 1))
        // Linear passthrough lifted by the floor (floor 0 → identity).
        #expect(approx(HapticCurve.intensity(0.5), HapticCurve.floor + (1 - HapticCurve.floor) * 0.5))
    }

    @Test func motorIntensitySpansFullRange() {
        #expect(HapticCurve.motorIntensity(0) == 0)
        #expect(approx(HapticCurve.motorIntensity(65535), 1))
        #expect(approx(HapticCurve.motorIntensity(32768), HapticCurve.intensity(32768.0 / 65535.0)))
    }

    @Test func combinedIntensityFollowsLouderMotor() {
        #expect(HapticCurve.combinedIntensity(low: 0, high: 0) == 0)
        #expect(approx(HapticCurve.combinedIntensity(low: 65535, high: 0), 1))
        #expect(approx(HapticCurve.combinedIntensity(low: 0, high: 65535), 1))
        #expect(HapticCurve.combinedIntensity(low: 30000, high: 10000)
                == HapticCurve.motorIntensity(30000))
    }
}
