import GameStreamProtocol

/// Pure connection-lifecycle policy: maps lifecycle events to phase transitions plus effects the shell performs.
/// The shell is a dumb interpreter, so every decision (retry budget, resume-stall prompt) stays here and stays testable.
public struct ConnectionStateMachine: Sendable {
    public enum Phase: Equatable, Sendable {
        case connecting
        case streaming
        case connectionLost   // an active stream dropped unexpectedly — offer reconnect
        case failed(String)
        case ended
    }

    public enum Event: Equatable, Sendable {
        case connectRequested
        /// Events-stream `connectionStarted` or successful `start()` — idempotent.
        case streamLive
        /// Failure before stream went live; message already formatted.
        case setupFailed(message: String)
        /// Session termination with its typed reason; graceful = the host ended the game cleanly.
        case terminated(reason: TerminationError)
        case retryTimerFired
        case userEnded
        /// A resumed encoder never re-armed (no video bytes in the grace window).
        case resumeStalled
        /// User accepted the stall prompt: tear down and relaunch the app fresh on the host.
        case relaunchRequested
        /// User declined the stall prompt: keep streaming.
        case resumeStalledDismissed
    }

    public enum Effect: Equatable, Sendable {
        case beginAttempt(forceLaunch: Bool)
        case tearDown
        case scheduleRetry(afterMillis: Int)
    }

    public private(set) var phase: Phase = .connecting
    /// True while the quit+relaunch prompt for a stalled resume is on screen.
    public private(set) var resumeStalled = false
    private var setupAttempts = 0
    /// Gate to ignore attempt outcomes once user ends/quits.
    private var userEnded = false
    private let maxSetupAttempts: Int
    private let retryDelayMillis: Int

    public init(maxSetupAttempts: Int = 3, retryDelayMillis: Int = 1500) {
        self.maxSetupAttempts = maxSetupAttempts
        self.retryDelayMillis = retryDelayMillis
    }

    public mutating func receive(_ event: Event) -> [Effect] {
        switch event {
        case .connectRequested:
            setupAttempts = 0
            userEnded = false
            resumeStalled = false
            phase = .connecting
            return [.beginAttempt(forceLaunch: false)]

        case .streamLive:
            guard !userEnded else { return [] }
            phase = .streaming
            resumeStalled = false
            return []

        case let .setupFailed(message):
            guard !userEnded else { return [] }
            if setupAttempts < maxSetupAttempts {
                setupAttempts += 1
                phase = .connecting
                return [.tearDown, .scheduleRetry(afterMillis: retryDelayMillis)]
            }
            phase = .failed(message)
            return [.tearDown]

        case let .terminated(reason):
            guard !userEnded, phase == .streaming else { return [] }
            // Graceful = the host ended the game: close cleanly. Anything else offers reconnect.
            phase = reason == .graceful ? .ended : .connectionLost
            resumeStalled = false
            return [.tearDown]

        case .retryTimerFired:
            guard !userEnded else { phase = .ended; return [] }
            return [.beginAttempt(forceLaunch: false)]

        case .userEnded:
            userEnded = true
            phase = .ended
            resumeStalled = false
            return [.tearDown]

        case .resumeStalled:
            guard !userEnded, phase == .streaming, !resumeStalled else { return [] }
            resumeStalled = true
            return []

        case .relaunchRequested:
            guard !userEnded, phase == .streaming, resumeStalled else { return [] }
            resumeStalled = false
            phase = .connecting
            return [.tearDown, .beginAttempt(forceLaunch: true)]

        case .resumeStalledDismissed:
            resumeStalled = false
            return []
        }
    }

    #if DEBUG
    /// Seed a machine already in a given phase, for SwiftUI previews of the adapter.
    public init(previewPhase: Phase) {
        self.init()
        self.phase = previewPhase
    }
    #endif
}
