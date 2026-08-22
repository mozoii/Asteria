import Foundation
import Synchronization

/// Transport seam for InputSender; ControlStream conforms.
public protocol InputTransport: Sendable {
    /// `reliable: false` sends on ENet's unreliable-sequenced path (relative motion); a lost packet is
    /// skipped, not retransmitted, so it can't head-of-line block the packets behind it.
    func send(_ message: ControlMessage.Message, channel: UInt8, reliable: Bool) async throws

    /// Push the queued batch onto the wire now. Called once after a flush's sends so reliable input
    /// (clicks/keys/gamepad edges) doesn't wait for the service grid, while the batch stays one datagram.
    func flush() async
}

/// Dedicated `.userInteractive` executor keeps flush loop off the cooperative pool, avoiding starvation by video-ingest task floods.
final class InputSendExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.mozoii.asteria.input-send", qos: .userInteractive)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// A per-frame controller state, in the host's integer domain (triggers 0…255, sticks −32768…32767).
/// The GameController layer converts float axes into this; the sender coalesces snapshots per controller.
public struct ControllerSnapshot: Sendable, Equatable {
    public var index: UInt8
    public var activeMask: UInt16
    public var buttonFlags: UInt32
    public var leftTrigger: UInt8
    public var rightTrigger: UInt8
    public var leftStickX: Int16
    public var leftStickY: Int16
    public var rightStickX: Int16
    public var rightStickY: Int16

    public init(index: UInt8, activeMask: UInt16, buttonFlags: UInt32,
                leftTrigger: UInt8, rightTrigger: UInt8,
                leftStickX: Int16, leftStickY: Int16, rightStickX: Int16, rightStickY: Int16) {
        self.index = index
        self.activeMask = activeMask
        self.buttonFlags = buttonFlags
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
    }
}

/// Coalesces input and flushes on a ~250 Hz tick; urgent events (button/key transitions, mouse) wake the flush sooner.
public final class InputSender: Sendable {
    private struct Buffer {
        var relDX = 0
        var relDY = 0
        var abs: (x: Int16, y: Int16, w: Int16, h: Int16)?
        var scrollV = 0
        var scrollH = 0
        var controllers: [UInt8: ControllerSnapshot] = [:]
        var discrete: [InputEncoder.Packet] = []
        var timerTask: Task<Void, Never>?
        var consumerTask: Task<Void, Never>?
        var running = false
        var sentCount = 0
        /// Oldest event timestamp for latency stat.
        var oldestEnqueueNanos: UInt64?
        var nextMouseSendNanos: UInt64 = 0
        var mouseFlushScheduled = false
    }

    /// Encoded continuous-input packet. `reliable` picks the ENet path (relative motion goes unreliable
    /// to dodge head-of-line blocking); `motion` carries the delta for re-banking on failure (abs/scroll dropped).
    private struct Outgoing {
        let packet: InputEncoder.Packet
        let reliable: Bool
        let motion: (dx: Int, dy: Int)?
    }

    /// Relative-mouse send-rate cap (1 ms): one packet per raw 1–8 kHz HID report floods the reliable channel and raises latency.
    private static let mouseBatchNanos: UInt64 = 1_000_000

    /// Tick and urgent events both yield here; one consumer drains it, keeping all sends serialized (down/up order).
    private let flushSignal: AsyncStream<Void>
    private let flushTrigger: AsyncStream<Void>.Continuation

    /// Total input packets handed to the transport so far (a tracer-bullet/telemetry signal).
    public var packetsSent: Int { state.withLock { $0.sentCount } }

    /// A live snapshot of the send path's health (coalescing, cadence, latency).
    public var stats: InputStats { tracker.snapshot() }

    private let state = Mutex(Buffer())
    private let transport: any InputTransport
    private let tickNanos: UInt64
    private let tracker: InputStatsTracker
    private let clock: @Sendable () -> UInt64
    /// Keeps flush loop off the cooperative pool (see `InputSendExecutor`).
    private let sendExecutor = InputSendExecutor()

    /// - Parameters:
    ///   - tickHz: flush rate (~250 Hz); higher = less latency, more churn.
    ///   - clock: monotonic nanosecond source (injectable for testability).
    public init(transport: any InputTransport, tickHz: UInt64 = 250,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.transport = transport
        self.tickNanos = 1_000_000_000 / max(1, tickHz)
        self.clock = clock
        self.tracker = InputStatsTracker(now: clock)
        let (signal, trigger) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.flushSignal = signal
        self.flushTrigger = trigger
    }

    private func signalFlush() { flushTrigger.yield() }

    /// Stamp the oldest-pending timestamp (first event after a flush) for the latency stat.
    private func note(_ b: inout Buffer) {
        if b.oldestEnqueueNanos == nil { b.oldestEnqueueNanos = clock() }
    }

    /// Start the flush loop; idempotent.
    public func start() {
        let tick = tickNanos
        state.withLock { b in
            guard !b.running else { return }
            b.running = true
            b.consumerTask = Task(executorPreference: sendExecutor) { [weak self] in
                guard let self else { return }
                for await _ in self.flushSignal { await self.flushOnce() }
            }
            b.timerTask = Task(executorPreference: sendExecutor) { [trigger = flushTrigger] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: tick)
                    trigger.yield()
                }
            }
        }
    }

    /// Stop the flush loop and drain anything still buffered.
    public func stop() async {
        let (timer, consumer) = state.withLock { b -> (Task<Void, Never>?, Task<Void, Never>?) in
            b.running = false
            defer { b.timerTask = nil; b.consumerTask = nil }
            return (b.timerTask, b.consumerTask)
        }
        timer?.cancel()
        consumer?.cancel()
        _ = await timer?.value
        _ = await consumer?.value
        await flushOnce()
    }

    public func mouseMoveRelative(deltaX: Int, deltaY: Int) {
        state.withLock { note(&$0); $0.relDX += deltaX; $0.relDY += deltaY }
        tracker.recordEnqueue()
        scheduleMouseFlush()
    }

    /// Send now if past the 1 ms cap, else schedule the burst's tail at the cap boundary so it isn't held for the tick.
    private func scheduleMouseFlush() {
        let now = clock()
        enum Action { case sendNow, schedule(UInt64), none }
        let action: Action = state.withLock { b in
            if now >= b.nextMouseSendNanos {
                b.nextMouseSendNanos = now &+ Self.mouseBatchNanos
                return .sendNow
            }
            if b.mouseFlushScheduled { return .none }
            b.mouseFlushScheduled = true
            return .schedule(b.nextMouseSendNanos &- now)
        }
        switch action {
        case .sendNow:
            signalFlush()
        case .schedule(let delay):
            Task(executorPreference: sendExecutor) { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard let self else { return }
                self.state.withLock { b in
                    b.mouseFlushScheduled = false
                    b.nextMouseSendNanos = self.clock() &+ Self.mouseBatchNanos
                }
                self.signalFlush()
            }
        case .none:
            break
        }
    }

    public func mouseMoveAbsolute(x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16) {
        state.withLock { note(&$0); $0.abs = (x, y, referenceWidth, referenceHeight) }
        tracker.recordEnqueue()
        scheduleMouseFlush()
    }

    public func scrollVertical(_ amount: Int) {
        state.withLock { note(&$0); $0.scrollV += amount }
        tracker.recordEnqueue()
    }

    public func scrollHorizontal(_ amount: Int) {
        state.withLock { note(&$0); $0.scrollH += amount }
        tracker.recordEnqueue()
    }

    public func mouseButton(_ button: UInt8, down: Bool) {
        enqueueDiscrete(InputEncoder.mouseButton(button, down: down))
    }

    public func keyboard(keyCode: Int16, down: Bool, modifiers: UInt8, flags: UInt8 = 0) {
        enqueueDiscrete(InputEncoder.keyboard(keyCode: keyCode, down: down, modifiers: modifiers, flags: flags))
    }

    public func controllerArrival(index: UInt8, type: UInt8,
                                  supportedButtonFlags: UInt32, capabilities: UInt16) {
        enqueueDiscrete(InputEncoder.controllerArrival(index: index, type: type,
                                                       supportedButtonFlags: supportedButtonFlags,
                                                       capabilities: capabilities))
    }

    public func controllerBattery(index: UInt8, state batteryState: UInt8, percentage: UInt8) {
        enqueueDiscrete(InputEncoder.controllerBattery(index: index, state: batteryState, percentage: percentage))
    }

    /// One-shot: tell the host we accept rumble (sent once at input start).
    public func enableHaptics() {
        enqueueDiscrete(InputEncoder.enableHaptics())
    }

    /// Coalesce a controller snapshot (latest-wins); a buttonFlags change first flushes the pending snapshot so the host gets the exact axes at the button edge.
    public func controller(_ snapshot: ControllerSnapshot) {
        state.withLock { b in
            note(&b)
            if let pending = b.controllers[snapshot.index], pending.buttonFlags != snapshot.buttonFlags {
                b.discrete.append(Self.encode(pending))
            }
            b.controllers[snapshot.index] = snapshot
        }
        tracker.recordEnqueue()
        signalFlush()
    }

    private func enqueueDiscrete(_ packet: InputEncoder.Packet) {
        state.withLock { note(&$0); $0.discrete.append(packet) }
        tracker.recordEnqueue()
        signalFlush()
    }

    /// Discrete events go first and reliably; relative motion follows on ENet's *unreliable* path so a
    /// dropped packet is skipped rather than head-of-line blocking the turn behind its retransmit.
    /// On throw: discrete re-enqueues (a missed key-up sticks the key on the host); motion re-banks
    /// (deltas additive); abs/scroll drop.
    func flushOnce() async {
        let (discrete, continuous, latency) = state.withLock { b -> ([InputEncoder.Packet], [Outgoing], UInt64) in
            let discrete = b.discrete
            b.discrete.removeAll(keepingCapacity: true)

            var cont: [Outgoing] = []
            var dx = b.relDX, dy = b.relDY
            b.relDX = 0; b.relDY = 0
            while dx != 0 || dy != 0 {
                let cx = Self.clampInt16(dx), cy = Self.clampInt16(dy)
                cont.append(Outgoing(packet: InputEncoder.mouseMoveRelative(deltaX: Int16(cx), deltaY: Int16(cy)),
                                     reliable: false, motion: (cx, cy)))
                dx -= cx; dy -= cy
            }

            if let a = b.abs {
                cont.append(Outgoing(packet: InputEncoder.mouseMoveAbsolute(x: a.x, y: a.y,
                                                                            referenceWidth: a.w, referenceHeight: a.h),
                                     reliable: false, motion: nil))
                b.abs = nil
            }

            var sv = b.scrollV; b.scrollV = 0
            while sv != 0 { let c = Self.clampInt16(sv); cont.append(Outgoing(packet: InputEncoder.scrollVertical(amount: Int16(c)), reliable: true, motion: nil)); sv -= c }
            var sh = b.scrollH; b.scrollH = 0
            while sh != 0 { let c = Self.clampInt16(sh); cont.append(Outgoing(packet: InputEncoder.scrollHorizontal(amount: Int16(c)), reliable: true, motion: nil)); sh -= c }

            for index in b.controllers.keys.sorted() {
                cont.append(Outgoing(packet: Self.encode(b.controllers[index]!), reliable: true, motion: nil))
            }
            b.controllers.removeAll(keepingCapacity: true)

            // Sample under the lock so the flush time can't predate a racing enqueue's stamp and wrap the subtraction.
            let flushNow = clock()
            let latency = b.oldestEnqueueNanos.map { $0 <= flushNow ? flushNow - $0 : 0 } ?? 0
            if !discrete.isEmpty || !cont.isEmpty { b.oldestEnqueueNanos = nil }
            return (discrete, cont, latency)
        }

        var delivered = 0

        // Discrete: reliable, order-preserving. On a transient throw, re-enqueue the failed packet and any
        // not-yet-attempted ones at the front so they retry next flush — never silently drop a key/button edge.
        for (i, packet) in discrete.enumerated() {
            do {
                try await transport.send(packet.message, channel: packet.channel, reliable: true)
                delivered += 1
            } catch {
                let remaining = Array(discrete[i...])
                state.withLock { b in
                    b.discrete.insert(contentsOf: remaining, at: 0)
                    if b.oldestEnqueueNanos == nil { b.oldestEnqueueNanos = clock() }
                }
                break
            }
        }

        // Continuous: motion unreliable + re-banked on throw (additive); abs/scroll latest-wins, dropped on throw.
        for item in continuous {
            do {
                try await transport.send(item.packet.message, channel: item.packet.channel, reliable: item.reliable)
                delivered += 1
            } catch {
                guard let m = item.motion else { continue }
                state.withLock { b in
                    b.relDX += m.dx; b.relDY += m.dy
                    if b.oldestEnqueueNanos == nil { b.oldestEnqueueNanos = clock() }
                }
            }
        }

        if delivered > 0 {
            await transport.flush()   // one datagram for the whole batch; no service-grid wait for reliable input
            state.withLock { $0.sentCount += delivered }
            tracker.recordFlush(packets: delivered, latencyNanos: latency)
        }
    }

    private static func encode(_ s: ControllerSnapshot) -> InputEncoder.Packet {
        InputEncoder.multiController(index: s.index, activeMask: s.activeMask, buttonFlags: s.buttonFlags,
                                     leftTrigger: s.leftTrigger, rightTrigger: s.rightTrigger,
                                     leftStickX: s.leftStickX, leftStickY: s.leftStickY,
                                     rightStickX: s.rightStickX, rightStickY: s.rightStickY)
    }

    private static func clampInt16(_ v: Int) -> Int {
        if v > Int(Int16.max) { return Int(Int16.max) }
        if v < Int(Int16.min) { return Int(Int16.min) }
        return v
    }
}

extension ControlStream: InputTransport {}
