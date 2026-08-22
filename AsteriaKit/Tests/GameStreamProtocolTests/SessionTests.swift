import Testing
@testable import GameStreamProtocol

@Suite("Connection session state machine")
struct SessionTests {
    struct MockError: Error, CustomStringConvertible {
        var description: String { "Permission denied: enable Launch applications." }
    }

    actor MockRunner: SessionRunner {
        enum Operation: Equatable {
            case prepare
            case negotiate
            case openMedia
        }

        private(set) var operations: [Operation] = []
        private(set) var closeCount = 0
        let failAt: ConnectionPhase?

        init(failAt: ConnectionPhase? = nil) {
            self.failAt = failAt
        }

        func prepareSession() async throws {
            try record(.prepare, phase: .preparingSession)
        }

        func negotiateSession() async throws {
            try record(.negotiate, phase: .negotiatingSession)
        }

        func openMediaPaths() async throws {
            try record(.openMedia, phase: .openingMediaPaths)
        }

        func closeSession() async {
            closeCount += 1
        }

        private func record(_ operation: Operation, phase: ConnectionPhase) throws {
            if phase == failAt { throw MockError() }
            operations.append(operation)
        }
    }

    private func collect(_ session: Session) -> Task<[SessionEvent], Never> {
        Task {
            var events: [SessionEvent] = []
            for await event in session.events { events.append(event) }
            return events
        }
    }

    @Test("Connection reports Asteria product phases in order")
    func reportsProductPhases() async {
        let runner = MockRunner()
        let session = Session(runner: runner)
        let events = collect(session)

        let result = await session.start()

        guard case .success = result else {
            Issue.record("expected start success")
            return
        }
        #expect(await session.phase == .streaming)
        await session.stop()
        #expect(await events.value == [
            .phaseChanged(.preparingSession),
            .phaseChanged(.negotiatingSession),
            .phaseChanged(.openingMediaPaths),
            .phaseChanged(.streaming),
            .connectionStarted,
            .phaseChanged(.idle),
            .connectionTerminated(.graceful),
        ])
        #expect(await runner.operations == [.prepare, .negotiate, .openMedia])
    }

    @Test("Failure identifies the product phase and closes partial resources")
    func failureClosesPartialResources() async {
        let runner = MockRunner(failAt: .negotiatingSession)
        let session = Session(runner: runner)
        let events = collect(session)

        let result = await session.start()

        guard case .failure = result else {
            Issue.record("expected start failure")
            return
        }
        #expect(await session.phase == .idle)
        #expect(await events.value == [
            .phaseChanged(.preparingSession),
            .phaseChanged(.negotiatingSession),
            .connectionFailed(
                phase: .negotiatingSession,
                message: "Permission denied: enable Launch applications."
            ),
            .phaseChanged(.idle),
        ])
        #expect(await runner.operations == [.prepare])
        #expect(await runner.closeCount == 1)
    }

    @Test("Start failure returns its phase and actionable detail directly")
    func startFailureReturnsDetail() async {
        let session = Session(runner: MockRunner(failAt: .preparingSession))

        let result = await session.start()

        guard case let .failure(failure) = result else {
            Issue.record("expected start failure")
            return
        }
        #expect(failure.phase == .preparingSession)
        #expect(failure.message == "Permission denied: enable Launch applications.")
    }

    @Test("stop carries its termination reason into the event stream")
    func stopCarriesReason() async {
        let session = Session(runner: MockRunner())
        let events = collect(session)

        await session.start()
        await session.stop(error: .unexpectedEarlyTermination)

        #expect(await events.value == [
            .phaseChanged(.preparingSession),
            .phaseChanged(.negotiatingSession),
            .phaseChanged(.openingMediaPaths),
            .phaseChanged(.streaming),
            .connectionStarted,
            .phaseChanged(.idle),
            .connectionTerminated(.unexpectedEarlyTermination),
        ])
    }

    @Test("watchdog reasons stop the session with the matching event")
    func stopWithWatchdogReasons() async {
        for reason in [TerminationError.noVideoTraffic, .noVideoFrame] {
            let session = Session(runner: MockRunner())
            let events = collect(session)

            await session.start()
            await session.stop(error: reason)

            let captured = await events.value
            #expect(captured.last == .connectionTerminated(reason))
        }
    }

    @Test("Stopping a stream closes resources once and returns to idle")
    func stopClosesResources() async {
        let runner = MockRunner()
        let session = Session(runner: runner)
        _ = collect(session)

        await session.start()
        await session.stop()
        await session.stop()

        #expect(await runner.closeCount == 1)
        #expect(await session.phase == .idle)
    }

    @Test("Link status is reported only while streaming")
    func reportStatusOnlyWhileStreaming() async {
        let runner = MockRunner()
        let session = Session(runner: runner)
        let events = collect(session)

        await session.reportStatus(.poor)
        await session.start()
        await session.reportStatus(.poor)
        await session.stop()

        let captured = await events.value
        #expect(captured.filter { $0 == .connectionStatusUpdate(.poor) }.count == 1)
    }
}
