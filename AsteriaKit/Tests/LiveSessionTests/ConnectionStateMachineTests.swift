import Testing
import GameStreamProtocol
@testable import LiveSession

@Suite struct ConnectionStateMachineTests {
    typealias SM = ConnectionStateMachine

    @Test("connectRequested begins a non-forced attempt from connecting")
    func connectRequested() {
        var m = SM()
        let fx = m.receive(.connectRequested)
        #expect(m.phase == .connecting)
        #expect(fx == [.beginAttempt(forceLaunch: false)])
    }

    @Test("streamLive moves to streaming")
    func streamLive() {
        var m = SM()
        _ = m.receive(.connectRequested)
        let fx = m.receive(.streamLive)
        #expect(m.phase == .streaming)
        #expect(fx == [])
    }

    @Test("streamLive is idempotent across both success signals")
    func streamLiveIdempotent() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.streamLive)
        let fx = m.receive(.streamLive)
        #expect(m.phase == .streaming)
        #expect(fx == [])
    }

    @Test("a setup failure with budget tears down and schedules a retry")
    func setupFailedRetries() {
        var m = SM()
        _ = m.receive(.connectRequested)
        let fx = m.receive(.setupFailed(message: "x"))
        #expect(m.phase == .connecting)
        #expect(fx == [.tearDown, .scheduleRetry(afterMillis: 1500)])
    }

    @Test("the retry timer begins another non-forced attempt")
    func retryTimerBeginsAttempt() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.setupFailed(message: "x"))
        let fx = m.receive(.retryTimerFired)
        #expect(fx == [.beginAttempt(forceLaunch: false)])
        #expect(m.phase == .connecting)
    }

    @Test("the setup budget fails after three retries")
    func setupBudgetExhausted() {
        var m = SM(maxSetupAttempts: 3)
        _ = m.receive(.connectRequested)
        for _ in 0..<3 {
            #expect(m.receive(.setupFailed(message: "x")) == [.tearDown, .scheduleRetry(afterMillis: 1500)])
            _ = m.receive(.retryTimerFired)
        }
        let fx = m.receive(.setupFailed(message: "final"))
        #expect(m.phase == .failed("final"))
        #expect(fx == [.tearDown])
    }

    @Test("quitting during the retry delay ends instead of reattempting")
    func quitDuringRetryDelay() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.setupFailed(message: "x"))   // schedules a retry
        _ = m.receive(.userEnded)
        let fx = m.receive(.retryTimerFired)
        #expect(m.phase == .ended)
        #expect(fx == [])
    }

    @Test("once ended, a stray streamLive is ignored")
    func endedGateStreamLive() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.userEnded)
        let fx = m.receive(.streamLive)
        #expect(m.phase == .ended)
        #expect(fx == [])
    }

    @Test("once ended, a stray setupFailed neither retries nor fails")
    func endedGateSetupFailed() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.userEnded)
        let fx = m.receive(.setupFailed(message: "x"))
        #expect(m.phase == .ended)
        #expect(fx == [])
    }

    @Test("an abnormal termination while streaming surfaces connectionLost")
    func terminatedWhileStreaming() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.streamLive)
        let fx = m.receive(.terminated(reason: .unexpectedEarlyTermination))
        #expect(m.phase == .connectionLost)
        #expect(fx == [.tearDown])
    }

    @Test("a graceful termination ends cleanly — no reconnect offer")
    func gracefulTerminationEnds() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.streamLive)
        let fx = m.receive(.terminated(reason: .graceful))
        #expect(m.phase == .ended)
        #expect(fx == [.tearDown])
    }

    @Test("watchdog terminations offer reconnect")
    func watchdogTerminationReconnects() {
        for reason in [TerminationError.noVideoTraffic, .noVideoFrame] {
            var m = SM()
            _ = m.receive(.connectRequested)
            _ = m.receive(.streamLive)
            _ = m.receive(.terminated(reason: reason))
            #expect(m.phase == .connectionLost)
        }
    }

    @Test("termination while only connecting is ignored")
    func terminatedWhileConnecting() {
        var m = SM()
        _ = m.receive(.connectRequested)
        let fx = m.receive(.terminated(reason: .graceful))
        #expect(m.phase == .connecting)
        #expect(fx == [])
    }

    @Test("user end from streaming tears down and ends")
    func userEndedFromStreaming() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.streamLive)
        let fx = m.receive(.userEnded)
        #expect(m.phase == .ended)
        #expect(fx == [.tearDown])
    }

    @Test("reconnect after ending clears the user-ended gate")
    func reconnectClearsGate() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.userEnded)
        let fx = m.receive(.connectRequested)
        #expect(m.phase == .connecting)
        #expect(fx == [.beginAttempt(forceLaunch: false)])
        _ = m.receive(.streamLive)   // gate cleared: streamLive now takes effect
        #expect(m.phase == .streaming)
    }

    @Test("a stalled resume while streaming flips the prompt flag, once")
    func resumeStalledOnce() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.streamLive)
        #expect(m.receive(.resumeStalled) == [])
        #expect(m.resumeStalled)
        #expect(m.receive(.resumeStalled) == [])   // already surfaced — no double-prompt
        #expect(m.resumeStalled)
    }

    @Test("a stall report while connecting is ignored")
    func resumeStalledWhileConnecting() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.resumeStalled)
        #expect(!m.resumeStalled)
        #expect(m.phase == .connecting)
    }

    @Test("relaunch tears down and forces a fresh launch")
    func relaunchForcesLaunch() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.streamLive)
        _ = m.receive(.resumeStalled)
        let fx = m.receive(.relaunchRequested)
        #expect(fx == [.tearDown, .beginAttempt(forceLaunch: true)])
        #expect(m.phase == .connecting)
        #expect(!m.resumeStalled)
    }

    @Test("relaunch without a surfaced stall is ignored")
    func relaunchRequiresStall() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.streamLive)
        #expect(m.receive(.relaunchRequested) == [])
        #expect(m.phase == .streaming)
    }

    @Test("dismissing the stall clears the prompt and keeps streaming")
    func dismissStall() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.streamLive)
        _ = m.receive(.resumeStalled)
        #expect(m.receive(.resumeStalledDismissed) == [])
        #expect(!m.resumeStalled)
        #expect(m.phase == .streaming)
    }

    @Test("termination during a surfaced stall clears it and offers reconnect")
    func terminationClearsStall() {
        var m = SM()
        _ = m.receive(.connectRequested)
        _ = m.receive(.streamLive)
        _ = m.receive(.resumeStalled)
        #expect(m.receive(.terminated(reason: .unexpectedEarlyTermination)) == [.tearDown])
        #expect(m.phase == .connectionLost)
        #expect(!m.resumeStalled)
    }
}
