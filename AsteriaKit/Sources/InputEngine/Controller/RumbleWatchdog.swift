import Foundation

/// One rumble target: a controller slot and a haptic locality.
struct RumbleKey: Hashable, Sendable {
    let slot: Int
    let locality: HapticLocality
}

/// Tracks when each locality was last driven non-zero so a host that goes silent mid-effect (crash,
/// dropped stream) can't latch rumble on forever. Time is injected so the policy is unit-testable.
final class RumbleWatchdog {
    private let timeoutNanos: UInt64
    private var lastActive: [RumbleKey: UInt64] = [:]

    init(timeoutNanos: UInt64 = 1_500_000_000) { self.timeoutNanos = timeoutNanos }

    /// Note that `key` was driven non-zero at monotonic time `now`.
    func active(_ key: RumbleKey, at now: UInt64) { lastActive[key] = now }

    /// Note that `key` was driven to zero (or otherwise cleared); stop tracking it.
    func idle(_ key: RumbleKey) { lastActive[key] = nil }

    /// Keys that have been silent longer than the timeout as of `now`.
    func expired(now: UInt64) -> [RumbleKey] {
        lastActive.compactMap { now &- $0.value > timeoutNanos ? $0.key : nil }
    }
}
