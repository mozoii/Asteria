import Testing
import Foundation
@testable import GameStreamProtocol

/// Guards that input send path stays responsive when cooperative pool is saturated.
/// Pre-fix: ~1–2 sends, thousands-ms latency; post-fix: hundreds, single-digit-ms.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ASTERIA_PERF_TESTS"] != nil,
                             "load-sensitive perf guard; set ASTERIA_PERF_TESTS to run in the perf lane"))
struct InputSenderContentionTests {
    /// Records send arrivals; confined to its own `.userInteractive` serial executor like ControlStream.
    private actor DedicatedRecorder: InputTransport {
        private let queue = DispatchSerialQueue(label: "test.input.recorder", qos: .userInteractive)
        nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
        private(set) var count = 0
        func send(_ message: ControlMessage.Message, channel: UInt8, reliable: Bool) async throws { count += 1 }
        func flush() async {}
    }

    /// Feed relative mouse at ~1 kHz from a dedicated high-QoS thread (mirrors the real input queue),
    /// so the producer itself is not subject to cooperative-pool starvation.
    private func driveMouse(_ sender: InputSender, millis: Int) {
        let t = Thread {
            let end = DispatchTime.now().uptimeNanoseconds &+ UInt64(millis) &* 1_000_000
            var next = DispatchTime.now().uptimeNanoseconds
            while DispatchTime.now().uptimeNanoseconds < end {
                sender.mouseMoveRelative(deltaX: 1, deltaY: 0)
                next &+= 1_000_000
                while DispatchTime.now().uptimeNanoseconds < next {}
            }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Oversubscribe the global cooperative pool with default-priority CPU tasks (the priority tier
    /// the send path's tasks would otherwise share) for `millis`, then stop. Self-terminating.
    private func floodPool(millis: Int) -> Thread {
        let t = Thread {
            let end = DispatchTime.now().uptimeNanoseconds &+ UInt64(millis) &* 1_000_000
            while DispatchTime.now().uptimeNanoseconds < end {
                for _ in 0..<250 {
                    Task.detached {
                        var acc: UInt64 = 0
                        for i in 0..<60_000 { acc = acc &* 1_103_515_245 &+ UInt64(i) }
                        if acc == 7 { fatalError() }
                    }
                }
                let burst = DispatchTime.now().uptimeNanoseconds &+ 5_000_000
                while DispatchTime.now().uptimeNanoseconds < burst {}
            }
        }
        t.qualityOfService = .userInitiated
        t.start()
        return t
    }

    @Test func flushStaysResponsiveUnderCooperativePoolSaturation() async throws {
        let rec = DedicatedRecorder()
        let sender = InputSender(transport: rec, tickHz: 250)
        sender.start()

        let load = floodPool(millis: 400)
        driveMouse(sender, millis: 400)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        await sender.stop()
        _ = load

        let stats = sender.stats
        let sent = await rec.count
        // Generous bounds: pre-fix this was ~1-2 sends with multi-thousand-ms latency; the QoS gap between
        // the .userInteractive send path and the default-priority flood keeps real numbers far below these.
        #expect(sent > 100, "send path starved under pool load: only \(sent) packets sent")
        #expect(stats.maxLatencyMillis < 150,
                "enqueue→flush latency spiked to \(stats.maxLatencyMillis)ms under pool load")
    }
}
