import Foundation
import Testing
@testable import GameStreamProtocol

private final class MockDatagramSource: DatagramSource, @unchecked Sendable {
    private let lock = NSLock()
    private var onDatagram: (@Sendable ([UInt8]) -> Void)?
    private var _sent: [[UInt8]] = []
    private var _stopped = false

    var sent: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _sent }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }

    func start(onDatagram: @escaping @Sendable ([UInt8]) -> Void) {
        lock.lock(); self.onDatagram = onDatagram; lock.unlock()
    }
    func send(_ datagram: [UInt8]) { lock.lock(); _sent.append(datagram); lock.unlock() }
    func stop() { lock.lock(); _stopped = true; lock.unlock() }

    func deliver(_ datagram: [UInt8]) {
        lock.lock(); let cb = onDatagram; lock.unlock()
        cb?(datagram)
    }
}

private final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
        lock.lock(); values.append(value); lock.unlock()
    }

    var snapshot: [Int] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

@Suite("RTP stream receiver")
struct RTPStreamReceiverTests {

    @Test func modernPingAppendsBigEndianSequence() {
        let payload = Array("0123456789ABCDEF".utf8)
        let d = RTPPing.datagram(payload: payload, seq: 0x01020304)
        #expect(d.count == 20)
        #expect(Array(d[0..<16]) == payload)
        #expect(Array(d[16..<20]) == [0x01, 0x02, 0x03, 0x04])
    }

    @Test func legacyPingWhenNoPayloadOrWrongLength() {
        #expect(RTPPing.datagram(payload: nil, seq: 5) == [0x50, 0x49, 0x4E, 0x47])
        #expect(RTPPing.datagram(payload: [1, 2, 3], seq: 5) == [0x50, 0x49, 0x4E, 0x47])
    }

    private func waitForStats<O>(
        _ receiver: RTPStreamReceiver<O>,
        until predicate: @Sendable (RTPStreamReceiver<O>.Stats) -> Bool
    ) async -> RTPStreamReceiver<O>.Stats {
        for _ in 0..<2000 {
            let s = await receiver.snapshot()
            if predicate(s) { return s }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await receiver.snapshot()
    }

    @Test func receiveLoopFeedsAssemblerAndCountsRecoveries() async throws {
        let source = MockDatagramSource()
        let receiver = RTPStreamReceiver<Int>(source: source, pingPayload: nil) { bytes in
            [(value: Int(bytes.first ?? 0), recovered: bytes.first == 1)]
        }
        await receiver.start()

        source.deliver([5])
        source.deliver([1])
        source.deliver([7])

        let s = await waitForStats(receiver) { $0.outputs >= 3 }
        #expect(s.datagrams == 3)
        #expect(s.bytes == 3)
        #expect(s.outputs == 3)
        #expect(s.recovered == 1)

        _ = await receiver.stop()
        #expect(source.stopped)
    }

    @Test func receiveLoopProcessesDatagramsSynchronouslyInDeliveryOrder() async throws {
        let source = MockDatagramSource()
        let recorder = OutputRecorder()
        let receiver = RTPStreamReceiver<Int>(source: source, pingPayload: nil) { bytes in
            return [(value: Int(bytes.first ?? 0), recovered: false)]
        }
        await receiver.start(onOutput: { recorder.append($0) })

        source.deliver([1])
        #expect(recorder.snapshot == [1])
        source.deliver([2])
        #expect(recorder.snapshot == [1, 2])

        let stats = await receiver.snapshot()
        #expect(stats.outputs == 2)
        _ = await receiver.stop()
    }

    @Test func startSendsNatPunchPings() async throws {
        let source = MockDatagramSource()
        let receiver = RTPStreamReceiver<Int>(source: source, pingPayload: nil, pingIntervalNanos: 1_000_000) { _ in [] }
        await receiver.start()

        var fired = false
        for _ in 0..<200 {
            if !source.sent.isEmpty { fired = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        _ = await receiver.stop()
        #expect(fired)
        #expect(source.sent.first == [0x50, 0x49, 0x4E, 0x47])
    }

    @Test("Ping-only mode (host-side audio) keeps pinging without decoding anything")
    func pingOnlyMode() async throws {
        let payload: [UInt8] = Array(repeating: 0xAB, count: 16)
        let source = MockDatagramSource()
        let receiver = RTPStreamReceiver<Int>(source: source, pingPayload: payload, pingIntervalNanos: 2_000_000) { _ in [] }
        await receiver.start(onOutput: nil)

        var pinged = false
        for _ in 0..<500 {
            if !source.sent.isEmpty { pinged = true; break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let stats = await receiver.stop()
        #expect(pinged)
        #expect(source.sent.first?.count == 20)
        #expect(Array(source.sent.first![0..<16]) == payload)
        #expect(stats.outputs == 0)
    }

    @Test("The last received datagram is timestamped in the stats")
    func lastActivityRecorded() async throws {
        let source = MockDatagramSource()
        let receiver = RTPStreamReceiver<Int>(source: source, pingPayload: nil) { _ in [] }
        await receiver.start()

        #expect((await receiver.snapshot()).lastActivityNanos == nil)
        source.deliver([9])
        let stats = await waitForStats(receiver) { $0.datagrams >= 1 }

        #expect(stats.lastActivityNanos != nil)
        // Must read as a past uptime value (not in the future).
        #expect(stats.lastActivityNanos! <= DispatchTime.now().uptimeNanoseconds)
        _ = await receiver.stop()
    }
}
