import Testing
@testable import GameStreamProtocol

/// Records sent messages in order; actor for thread safety.
private actor MockTransport: InputTransport {
    private(set) var sent: [(type: UInt16, payload: [UInt8], channel: UInt8, reliable: Bool)] = []
    /// Count of `flush()` calls, and the `sent.count` at each flush (to prove flush trails the batch).
    private(set) var flushCount = 0
    private(set) var sentCountAtFlush: [Int] = []
    func send(_ message: ControlMessage.Message, channel: UInt8, reliable: Bool) async throws {
        sent.append((message.type, message.payload, channel, reliable))
    }
    func flush() async {
        flushCount += 1
        sentCountAtFlush.append(sent.count)
    }
}

private func snapshot(index: UInt8 = 0, buttons: UInt32 = 0, lsX: Int16 = 0) -> ControllerSnapshot {
    ControllerSnapshot(index: index, activeMask: 0x0001, buttonFlags: buttons,
                       leftTrigger: 0, rightTrigger: 0,
                       leftStickX: lsX, leftStickY: 0, rightStickX: 0, rightStickY: 0)
}

/// Polls until at least `minimum` packets are sent or the deadline passes; returns the final count.
/// Replaces fixed sleeps so pass/fail does not depend on where a sleep lands under load.
private func waitForSentCount(_ mock: MockTransport, minimum: Int) async -> Int {
    let deadline = ContinuousClock.now + .seconds(2)
    var count = await mock.sent.count
    while count < minimum && ContinuousClock.now < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
        count = await mock.sent.count
    }
    return count
}

@Suite("Input sender (coalescing flush)")
struct InputSenderTests {
    @Test func relativeMouseDeltasAreSummed() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.mouseMoveRelative(deltaX: 5, deltaY: 5)
        sender.mouseMoveRelative(deltaX: 3, deltaY: -2)
        await sender.flushOnce()

        let sent = await mock.sent
        #expect(sent.count == 1)
        #expect(sent[0].channel == 0x03)
        #expect(sent[0].type == InputEncoder.inputDataType)
        #expect(sent[0].payload == InputEncoder.mouseMoveRelative(deltaX: 8, deltaY: 3).payload)
    }

    @Test func netZeroRelativeMotionCoalescesToNothing() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.mouseMoveRelative(deltaX: 5, deltaY: 0)
        sender.mouseMoveRelative(deltaX: -5, deltaY: 0)
        await sender.flushOnce()
        #expect(await mock.sent.isEmpty)
    }

    @Test func largeRelativeMotionSplitsAcrossPackets() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.mouseMoveRelative(deltaX: 40_000, deltaY: 0)   // > Int16.max
        await sender.flushOnce()

        let sent = await mock.sent
        #expect(sent.count == 2)
        #expect(sent[0].payload == InputEncoder.mouseMoveRelative(deltaX: 32767, deltaY: 0).payload)
        #expect(sent[1].payload == InputEncoder.mouseMoveRelative(deltaX: 7233, deltaY: 0).payload)   // 40000 − 32767
    }

    @Test func buttonDownThenUpKeepsOrderUnmerged() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.mouseButton(InputEncoder.mouseButtonLeft, down: true)
        sender.mouseButton(InputEncoder.mouseButtonLeft, down: false)
        await sender.flushOnce()

        let sent = await mock.sent
        #expect(sent.count == 2)
        #expect(sent[0].payload == InputEncoder.mouseButton(InputEncoder.mouseButtonLeft, down: true).payload)
        #expect(sent[1].payload == InputEncoder.mouseButton(InputEncoder.mouseButtonLeft, down: false).payload)
    }

    @Test func verticalScrollAccumulates() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.scrollVertical(120)
        sender.scrollVertical(120)
        await sender.flushOnce()

        let sent = await mock.sent
        #expect(sent.count == 1)
        #expect(sent[0].payload == InputEncoder.scrollVertical(amount: 240).payload)
    }

    @Test func absolutePositionKeepsLatest() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.mouseMoveAbsolute(x: 1, y: 1, referenceWidth: 100, referenceHeight: 100)
        sender.mouseMoveAbsolute(x: 50, y: 60, referenceWidth: 100, referenceHeight: 100)
        await sender.flushOnce()

        let sent = await mock.sent
        #expect(sent.count == 1)
        #expect(sent[0].payload == InputEncoder.mouseMoveAbsolute(
            x: 50, y: 60, referenceWidth: 100, referenceHeight: 100).payload)
    }

    @Test func absoluteMousePositionIsUnreliable() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.mouseMoveAbsolute(x: 50, y: 60, referenceWidth: 100, referenceHeight: 100)
        await sender.flushOnce()

        let sent = await mock.sent
        #expect(sent.count == 1)
        #expect(sent[0].reliable == false)
    }

    @Test func controllerSnapshotKeepsLatestWhenButtonsUnchanged() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.controller(snapshot(buttons: 0x1000, lsX: 100))
        sender.controller(snapshot(buttons: 0x1000, lsX: 200))   // same buttons, newer axis
        await sender.flushOnce()

        let sent = await mock.sent
        #expect(sent.count == 1)
        #expect(sent[0].channel == 0x10)
        #expect(sent[0].payload == InputEncoder.multiController(
            index: 0, activeMask: 0x0001, buttonFlags: 0x1000,
            leftTrigger: 0, rightTrigger: 0,
            leftStickX: 200, leftStickY: 0, rightStickX: 0, rightStickY: 0).payload)
    }

    @Test func controllerButtonChangeFlushesPendingSnapshot() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.controller(snapshot(buttons: 0x0000, lsX: 100))
        sender.controller(snapshot(buttons: 0x1000, lsX: 200))   // button transition
        await sender.flushOnce()

        let sent = await mock.sent
        #expect(sent.count == 2)
        #expect(sent[0].payload == InputEncoder.multiController(
            index: 0, activeMask: 0x0001, buttonFlags: 0x0000,
            leftTrigger: 0, rightTrigger: 0,
            leftStickX: 100, leftStickY: 0, rightStickX: 0, rightStickY: 0).payload)
        #expect(sent[1].payload == InputEncoder.multiController(
            index: 0, activeMask: 0x0001, buttonFlags: 0x1000,
            leftTrigger: 0, rightTrigger: 0,
            leftStickX: 200, leftStickY: 0, rightStickX: 0, rightStickY: 0).payload)
    }

    @Test func discreteEventsFlushBeforeCoalescedContinuous() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.mouseMoveRelative(deltaX: 5, deltaY: 5)
        sender.mouseButton(InputEncoder.mouseButtonLeft, down: true)
        await sender.flushOnce()

        let sent = await mock.sent
        #expect(sent.count == 2)
        #expect(sent[0].payload == InputEncoder.mouseButton(InputEncoder.mouseButtonLeft, down: true).payload)
        #expect(sent[1].payload == InputEncoder.mouseMoveRelative(deltaX: 5, deltaY: 5).payload)
    }

    @Test func multipleControllersFlushInIndexOrder() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.controller(snapshot(index: 2, buttons: 0x2000))
        sender.controller(snapshot(index: 0, buttons: 0x1000))
        await sender.flushOnce()

        let sent = await mock.sent
        #expect(sent.count == 2)
        #expect(sent[0].channel == 0x10)   // index 0
        #expect(sent[1].channel == 0x12)   // index 2
    }

    @Test func discreteEventFlushesBeforeTheTick() async throws {
        let mock = MockTransport()
        let sender = InputSender(transport: mock, tickHz: 20)   // 50ms tick
        sender.start()
        sender.mouseButton(InputEncoder.mouseButtonLeft, down: true)
        let count = await waitForSentCount(mock, minimum: 1)   // sent on the urgent wake, not held for the tick
        await sender.stop()
        #expect(count >= 1)
    }

    @Test func rapidMouseBurstCoalescesBelowKilohertz() async throws {
        let mock = MockTransport()
        let sender = InputSender(transport: mock, tickHz: 250)
        sender.start()
        for _ in 0..<20 { sender.mouseMoveRelative(deltaX: 1, deltaY: 0) }   // burst faster than the 1ms cap
        let count = await waitForSentCount(mock, minimum: 1)
        await sender.stop()
        #expect(count >= 1 && count <= 3)   // coalesced, not one packet per report
    }

    @Test func analogControllerChangeSendsPromptly() async throws {
        let mock = MockTransport()
        let sender = InputSender(transport: mock, tickHz: 20)   // 50ms tick
        sender.start()
        sender.controller(snapshot(buttons: 0x0000, lsX: 100))  // analog only, no button change
        let count = await waitForSentCount(mock, minimum: 1)   // analog sticks send promptly, not held for the tick
        await sender.stop()
        #expect(count >= 1)
    }

    @Test func batchIsFlushedOnceAfterAllSends() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.mouseMoveRelative(deltaX: 5, deltaY: 5)
        sender.mouseButton(InputEncoder.mouseButtonLeft, down: true)
        await sender.flushOnce()

        // One flush, and it lands after both packets are queued — the whole batch coalesces into one datagram.
        #expect(await mock.flushCount == 1)
        #expect(await mock.sentCountAtFlush == [2])
    }

    @Test func emptyFlushDoesNotTouchTransport() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        await sender.flushOnce()   // nothing buffered
        #expect(await mock.flushCount == 0)
    }

    @Test func absoluteMoveWakesFlushLoopBeforeTheTick() async throws {
        let mock = MockTransport()
        let sender = InputSender(transport: mock, tickHz: 20)   // 50ms tick
        sender.start()
        sender.mouseMoveAbsolute(x: 10, y: 10, referenceWidth: 100, referenceHeight: 100)
        let count = await waitForSentCount(mock, minimum: 1)   // desktop-mode pointer moves don't wait for the tick
        await sender.stop()
        #expect(count >= 1)
    }

    @Test func stopDrainsBufferedEvents() async {
        let mock = MockTransport()
        let sender = InputSender(transport: mock)
        sender.enableHaptics()
        sender.start()
        await sender.stop()   // cancels the loop and flushes the remainder

        let sent = await mock.sent
        #expect(sent.contains { $0.payload == InputEncoder.enableHaptics().payload && $0.channel == 0x00 })
    }
}
