import Testing
@testable import InputEngine

@Suite("Rumble watchdog")
struct RumbleWatchdogTests {
    private let key = RumbleKey(slot: 0, locality: .leftHandle)
    private let other = RumbleKey(slot: 0, locality: .rightHandle)

    @Test("a non-zero key expires once it has been silent past the timeout")
    func expiresAfterTimeout() {
        let wd = RumbleWatchdog(timeoutNanos: 1_000)
        wd.active(key, at: 0)
        #expect(wd.expired(now: 500).isEmpty)          // within timeout
        #expect(wd.expired(now: 1_500) == [key])       // past timeout
    }

    @Test("re-arming pushes the deadline forward")
    func reArmResetsDeadline() {
        let wd = RumbleWatchdog(timeoutNanos: 1_000)
        wd.active(key, at: 0)
        wd.active(key, at: 900)                         // still streaming
        #expect(wd.expired(now: 1_500).isEmpty)        // measured from 900, not 0
        #expect(wd.expired(now: 2_000) == [key])
    }

    @Test("an explicit zero stops tracking so nothing expires")
    func idleClearsTracking() {
        let wd = RumbleWatchdog(timeoutNanos: 1_000)
        wd.active(key, at: 0)
        wd.idle(key)
        #expect(wd.expired(now: 10_000).isEmpty)
    }

    @Test("only the silent key expires; a freshly re-armed one survives")
    func perKeyDeadlines() {
        let wd = RumbleWatchdog(timeoutNanos: 1_000)
        wd.active(key, at: 0)
        wd.active(other, at: 1_800)
        #expect(wd.expired(now: 2_000) == [key])
    }
}
