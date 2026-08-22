import Foundation
import CENet

public enum ControlStreamError: Error, Equatable {
    case hostCreateFailed
    case connectFailed
    case connectTimedOut
    case sendFailed
    case notConnected
}

/// Reliable-UDP control stream over ENet with AES-GCM encryption and periodic pings.
public actor ControlStream {
    private let host: String
    private let port: UInt16
    private let connectData: UInt32
    private let crypto: ControlCrypto

    /// Dedicated `.userInteractive` serial executor off Swift's cooperative pool to avoid input starvation; serializes ENet operations.
    private let executorQueue = DispatchSerialQueue(label: "io.github.mozoii.asteria.control",
                                                    qos: .userInteractive)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }

    /// Control messages received from the host, yielded as they arrive.
    public nonisolated let hostMessages: AsyncStream<HostControlMessage>
    private nonisolated let hostContinuation: AsyncStream<HostControlMessage>.Continuation

    /// Yields once when the ENet peer disconnects (host terminated or the network died), then ends.
    public nonisolated let disconnects: AsyncStream<Void>
    private nonisolated let disconnectsContinuation: AsyncStream<Void>.Continuation

    private var enetHost: UnsafeMutablePointer<ENetHost>?
    private var peer: UnsafeMutablePointer<ENetPeer>?
    private var seq: UInt32 = 0
    private var serviceTask: Task<Void, Never>?
    private var msSinceLastPing: UInt64 = 0

    /// Background service loop interval; bounds reliable-input latency (unreliable motion flushes in `send`).
    private static let serviceIntervalMs: UInt64 = 2

    /// ENet's mean reliable-packet RTT (ms); 0 before the first acknowledgement.
    public var roundTripTimeMillis: UInt32 { peer?.pointee.roundTripTime ?? 0 }

    public init(host: String, port: UInt16, connectData: UInt32, rikey: [UInt8]) {
        self.host = host
        self.port = port
        self.connectData = connectData
        self.crypto = ControlCrypto(rikey: rikey)
        (self.hostMessages, self.hostContinuation) =
            AsyncStream<HostControlMessage>.makeStream(bufferingPolicy: .bufferingNewest(64))
        (self.disconnects, self.disconnectsContinuation) = AsyncStream<Void>.makeStream()
    }

    /// Connect the ENet peer and run the start sequence.
    public func connect(timeoutMs: UInt32 = 10_000) throws {
        ENet.initializeIfNeeded()

        var address = ENetAddress()
        _ = host.withCString { enet_address_set_host(&address, $0) }
        enet_address_set_port(&address, port)

        let family = Int32(address.address.ss_family)
        guard let client = enet_host_create(family, nil, 1, ControlMessage.channelCount, 0, 0) else {
            throw ControlStreamError.hostCreateFailed
        }
        self.enetHost = client
        // QOS=1 → SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VO, the AC_VO class: the control/input
        // uplink is the most latency-critical traffic, ranked above the AC_VI video/audio sockets.
        enet_socket_set_option(client.pointee.socket, ENET_SOCKOPT_QOS, 1)

        guard let peer = enet_host_connect(client, &address, ControlMessage.channelCount, connectData) else {
            cleanup()
            throw ControlStreamError.connectFailed
        }
        self.peer = peer

        var event = ENetEvent()
        let result = enet_host_service(client, &event, timeoutMs)
        guard result > 0, event.type == ENET_EVENT_TYPE_CONNECT else {
            cleanup()
            throw result == 0 ? ControlStreamError.connectTimedOut : ControlStreamError.connectFailed
        }
        enet_host_flush(client)
        enet_peer_timeout(peer, 2, 10_000, 10_000)

        try send(ControlMessage.startA, channel: ControlMessage.channelGeneric)
        try send(ControlMessage.startB, channel: ControlMessage.channelGeneric)
        enet_host_flush(client)   // send no longer flushes; push the handshake now (service loop starts later)
    }

    /// Start the background service loop; drains ENet events and emits keepalive pings.
    public func startServiceLoop() {
        guard serviceTask == nil else { return }
        serviceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.serviceOnce() {
                    self.disconnectsContinuation.yield()
                    self.disconnectsContinuation.finish()
                    return
                }
                try? await Task.sleep(nanoseconds: Self.serviceIntervalMs * 1_000_000)
            }
        }
    }

    /// One service pass; returns true if peer disconnected.
    private func serviceOnce() -> Bool {
        guard let enetHost else { return true }
        var event = ENetEvent()
        while enet_host_service(enetHost, &event, 0) > 0 {
            if event.type == ENET_EVENT_TYPE_DISCONNECT { return true }
            if event.type == ENET_EVENT_TYPE_RECEIVE {
                if let packet = event.packet, let data = packet.pointee.data, packet.pointee.dataLength > 0 {
                    let bytes = Array(UnsafeBufferPointer(start: data, count: packet.pointee.dataLength))
                    if let (type, payload) = try? crypto.open(bytes, origin: .host) {
                        hostContinuation.yield(HostControlDecoder.decode(type: type, payload: payload))
                    }
                }
                enet_packet_destroy(event.packet)
            }
        }
        msSinceLastPing += Self.serviceIntervalMs
        if msSinceLastPing >= ControlMessage.pingIntervalMs {
            msSinceLastPing = 0
            try? send(ControlMessage.ping, channel: ControlMessage.channelGeneric)
        }
        return false
    }

    /// Encrypt and queue. `reliable: false` uses ENet's unreliable-sequenced path so a lost packet is
    /// skipped rather than retransmitted — relative motion can't head-of-line block the turn behind it.
    /// `seq` advances per packet (it's the GCM nonce, carried in-packet), so loss gaps are harmless.
    public func send(_ message: ControlMessage.Message, channel: UInt8, reliable: Bool = true) throws {
        guard let peer else { throw ControlStreamError.notConnected }
        let bytes = try crypto.seal(type: message.type, payload: message.payload, seq: seq)
        seq &+= 1
        let flags: UInt32 = reliable ? ENET_PACKET_FLAG_RELIABLE.rawValue : 0
        let packet = bytes.withUnsafeBytes {
            enet_packet_create($0.baseAddress, bytes.count, flags)
        }
        guard enet_peer_send(peer, channel, packet) == 0 else { throw ControlStreamError.sendFailed }
    }

    /// Push queued packets onto the wire now. `InputSender` calls this once after each flush batch, so
    /// reliable input (clicks/keys/gamepad edges) doesn't wait for the 2 ms service grid.
    public func flush() {
        if let enetHost { enet_host_flush(enetHost) }
    }

    public func disconnect() {
        serviceTask?.cancel(); serviceTask = nil
        hostContinuation.finish()
        // Client-initiated teardown: end the disconnects stream without a yield (no host event to report).
        disconnectsContinuation.finish()
        if let peer { enet_peer_disconnect_now(peer, 0); self.peer = nil }
        cleanup()
    }

    private func cleanup() {
        if let enetHost { enet_host_destroy(enetHost); self.enetHost = nil }
        peer = nil
    }
}
