import Foundation
import Network

public protocol DatagramSource: Sendable {
    /// The callback must be invoked serially in datagram delivery order.
    func start(onDatagram: @escaping @Sendable ([UInt8]) -> Void)
    func send(_ datagram: [UInt8])
    func stop()
}

enum RTPPing {
    static func datagram(payload: [UInt8]?, seq: UInt32) -> [UInt8] {
        if let payload, payload.count == 16 {
            return payload + [UInt8(seq >> 24), UInt8((seq >> 16) & 0xFF), UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF)]
        }
        return [0x50, 0x49, 0x4E, 0x47]   // "PING"
    }
}

public final class NWDatagramSource: DatagramSource, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    let parameters: NWParameters
    private let queue = DispatchQueue(label: "io.github.mozoii.Asteria.rtp-udp", qos: .userInteractive)
    private let lock = NSLock()
    private var connection: NWConnection?

    public init(host: String, port: UInt16, parameters: NWParameters = NetworkQoS.streamUDPParameters()) {
        self.host = host
        self.port = port
        self.parameters = parameters
    }

    public func start(onDatagram: @escaping @Sendable ([UInt8]) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        lock.lock(); connection = conn; lock.unlock()
        conn.stateUpdateHandler = { state in
            if case .ready = state { Self.receiveLoop(conn, onDatagram) }
        }
        conn.start(queue: queue)
    }

    public func send(_ datagram: [UInt8]) {
        lock.lock(); let conn = connection; lock.unlock()
        conn?.send(content: Data(datagram), completion: .idempotent)
    }

    public func stop() {
        lock.lock(); let conn = connection; connection = nil; lock.unlock()
        conn?.cancel()
    }

    private static func receiveLoop(_ conn: NWConnection, _ onDatagram: @escaping @Sendable ([UInt8]) -> Void) {
        conn.receiveMessage { data, _, _, error in
            if let data, !data.isEmpty { onDatagram([UInt8](data)) }
            if error == nil { receiveLoop(conn, onDatagram) }
        }
    }
}
