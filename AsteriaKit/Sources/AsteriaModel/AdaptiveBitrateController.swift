/// Pure adaptive-bitrate state machine, ticked once per second with the loss rate: cuts fast under loss,
/// probes back toward the Auto ceiling after a loss-free stretch. `mode` tunes aggressiveness.
public struct AdaptiveBitrateController: Equatable, Sendable {
    /// Per-mode tuning knobs.
    public struct Policy: Equatable, Sendable {
        /// Loss (%) at/above which the rate is cut hard, and the gentler threshold below it.
        let heavyLossPercent: Double
        let mildLossPercent: Double
        /// Multipliers applied on a heavy / mild cut.
        let heavyCut: Double
        let mildCut: Double
        /// Loss-free seconds required before probing the rate up.
        let probeAfterStableSeconds: Int
        /// Probe multiplier; the cautious variant is used for the first probe after a cut.
        let probeStep: Double
        let cautiousProbeStep: Double
        /// Floor as a fraction of the ceiling (the initial/Auto rate).
        let floorFraction: Double

        public static func of(_ mode: AdaptiveMode) -> Policy {
            switch mode {
            case .preferQuality:
                return Policy(heavyLossPercent: 8, mildLossPercent: 4, heavyCut: 0.80, mildCut: 0.92,
                              probeAfterStableSeconds: 3, probeStep: 1.08, cautiousProbeStep: 1.03,
                              floorFraction: 0.60)
            case .preferLatency:
                return Policy(heavyLossPercent: 3, mildLossPercent: 1, heavyCut: 0.60, mildCut: 0.80,
                              probeAfterStableSeconds: 6, probeStep: 1.04, cautiousProbeStep: 1.02,
                              floorFraction: 0.35)
            }
        }
    }

    /// Below this the stream is unwatchable, so the floor never drops under it regardless of mode.
    public static let absoluteFloorKbps = 2_000

    /// The Auto value; adaptive never exceeds it.
    public let ceilingKbps: Int
    public private(set) var currentKbps: Int
    private var mode: AdaptiveMode
    private var policy: Policy
    private var stableSeconds = 0
    /// The last rate change was a cut, so the next probe steps up cautiously.
    private var lastChangeWasCut = false

    public var floorKbps: Int {
        min(ceilingKbps, max(Self.absoluteFloorKbps, Int(Double(ceilingKbps) * policy.floorFraction)))
    }

    public init(initialKbps: Int, mode: AdaptiveMode) {
        self.mode = mode
        self.policy = .of(mode)
        self.ceilingKbps = max(1, initialKbps)
        self.currentKbps = max(1, initialKbps)
    }

    /// Swap the aggressiveness policy live (e.g. from the in-stream menu). Re-clamps the current rate into the
    /// new band; returns the new target when the clamp moved it, else nil.
    @discardableResult
    public mutating func setMode(_ newMode: AdaptiveMode) -> Int? {
        guard newMode != mode else { return nil }
        mode = newMode
        policy = .of(newMode)
        stableSeconds = 0
        let clamped = clamp(currentKbps)
        guard clamped != currentKbps else { return nil }
        currentKbps = clamped
        return currentKbps
    }

    /// Feed one second of loss telemetry; returns a new target when the rate changes, else nil.
    public mutating func tick(lossPercent: Double) -> Int? {
        var target = currentKbps
        if lossPercent >= policy.heavyLossPercent {
            target = scaled(policy.heavyCut); stableSeconds = 0; lastChangeWasCut = true
        } else if lossPercent >= policy.mildLossPercent {
            target = scaled(policy.mildCut); stableSeconds = 0; lastChangeWasCut = true
        } else {
            stableSeconds += 1
            if stableSeconds >= policy.probeAfterStableSeconds, currentKbps < ceilingKbps {
                target = Int(Double(currentKbps) * (lastChangeWasCut ? policy.cautiousProbeStep : policy.probeStep))
                stableSeconds = 0
                lastChangeWasCut = false
            }
        }
        let clamped = clamp(target)
        guard clamped != currentKbps else { return nil }
        currentKbps = clamped
        return currentKbps
    }

    private func scaled(_ factor: Double) -> Int { Int(Double(currentKbps) * factor) }
    private func clamp(_ v: Int) -> Int { min(ceilingKbps, max(floorKbps, v)) }
}
