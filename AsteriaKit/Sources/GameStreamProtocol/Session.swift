import Foundation

/// Connection termination reasons. Graceful is normal stop; negatives are abnormal.
public enum TerminationError: Int, Sendable, Error, Equatable {
    case graceful = 0
    case noVideoTraffic = -100
    case noVideoFrame = -101
    case unexpectedEarlyTermination = -102
    case protectedContent = -103
    case frameConversion = -104
}

/// A failed connection attempt, preserving the phase and underlying setup detail for callers.
public struct SessionStartFailure: Error, Equatable, Sendable {
    public let phase: ConnectionPhase
    public let message: String
    public let termination: TerminationError

    public init(phase: ConnectionPhase, message: String,
                termination: TerminationError = .unexpectedEarlyTermination) {
        self.phase = phase
        self.message = message
        self.termination = termination
    }
}

public enum ConnectionStatus: Int, Sendable, Equatable {
    case okay = 0
    case poor = 1
}

/// Lifecycle events from a Session. Media and input feedback belong to their owning engines.
public enum SessionEvent: Sendable, Equatable {
    case phaseChanged(ConnectionPhase)
    case connectionFailed(phase: ConnectionPhase, message: String)
    case connectionStarted
    case connectionStatusUpdate(ConnectionStatus)
    case connectionTerminated(TerminationError)
}

/// Owns the protocol negotiation and resources behind product-level connection progress.
public protocol SessionRunner: Sendable {
    func prepareSession() async throws
    func negotiateSession() async throws
    func openMediaPaths() async throws
    func closeSession() async
}

public actor Session {
    private let runner: SessionRunner
    private var continuation: AsyncStream<SessionEvent>.Continuation?
    private var finished = false

    public private(set) var phase: ConnectionPhase = .idle
    /// Lifecycle event stream (unbounded buffering; finishes on termination).
    public nonisolated let events: AsyncStream<SessionEvent>

    public init(runner: SessionRunner) {
        self.runner = runner
        var cont: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    private func emit(_ event: SessionEvent) { continuation?.yield(event) }

    /// Establish a connection and report product-level progress.
    @discardableResult
    public func start() async -> Result<Void, SessionStartFailure> {
        guard phase == .idle, !finished else {
            return .failure(SessionStartFailure(
                phase: phase,
                message: "The stream session cannot be started more than once."
            ))
        }
        do {
            setPhase(.preparingSession)
            try await runner.prepareSession()
            setPhase(.negotiatingSession)
            try await runner.negotiateSession()
            setPhase(.openingMediaPaths)
            try await runner.openMediaPaths()
        } catch {
            let failure = SessionStartFailure(phase: phase, message: "\(error)")
            emit(.connectionFailed(phase: failure.phase, message: failure.message))
            await runner.closeSession()
            setPhase(.idle)
            finishEvents()
            return .failure(failure)
        }
        setPhase(.streaming)
        emit(.connectionStarted)
        return .success(())
    }

    /// Close all connection resources and return to idle. Idempotent.
    public func stop(error: TerminationError = .graceful) async {
        guard phase != .idle, !finished else { return }
        await runner.closeSession()
        setPhase(.idle)
        emit(.connectionTerminated(error))
        finishEvents()
    }

    /// Report host link quality. Ignored unless streaming.
    public func reportStatus(_ status: ConnectionStatus) {
        guard phase == .streaming else { return }
        emit(.connectionStatusUpdate(status))
    }

    private func setPhase(_ next: ConnectionPhase) {
        phase = next
        emit(.phaseChanged(next))
    }

    private func finishEvents() {
        finished = true
        continuation?.finish()
        continuation = nil
    }
}
