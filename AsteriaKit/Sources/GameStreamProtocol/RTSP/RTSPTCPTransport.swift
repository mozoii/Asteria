import Foundation
import Network

/// Accumulates bytes and yields complete RTSP responses (Content-Length-delimited or EOF).
public struct RTSPResponseFramer {
    private var buffer = Data()

    public init() {}

    /// Append bytes. Returns response once Content-Length-delimited message is complete; call `finish()` at EOF.
    public mutating func append(_ data: Data) -> RTSPResponse? {
        buffer.append(data)
        let crlf2 = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.firstRange(of: crlf2) else { return nil }

        let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        guard let contentLength = Self.contentLength(headerText) else { return nil }  // no CL ⇒ close-delimited
        let needed = (headerEnd.upperBound - buffer.startIndex) + contentLength
        guard buffer.count >= needed else { return nil }

        let messageEnd = buffer.index(buffer.startIndex, offsetBy: needed)
        let message = Data(buffer[buffer.startIndex..<messageEnd])
        buffer.removeSubrange(buffer.startIndex..<messageEnd)
        return RTSPResponse(parsing: message)
    }

    /// Parse buffered data as close-delimited message (call at EOF).
    public mutating func finish() -> RTSPResponse? {
        defer { buffer.removeAll() }
        return RTSPResponse(parsing: buffer)
    }

    mutating func ingest(_ data: Data, endOfStream: Bool) throws -> RTSPResponse? {
        if let response = append(data) { return response }
        guard endOfStream else { return nil }
        if let response = finish() { return response }
        throw RTSPError.transport("connection closed before a complete response")
    }

    private static func contentLength(_ headerText: String) -> Int? {
        for line in headerText.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" { return Int(parts[1]) }
        }
        return nil
    }
}

/// Live RTSP transport over Network.framework. Connects fresh per request (host closes after each reply).
public struct RTSPTCPTransport: RTSPTransport {
    private let host: String
    private let port: UInt16
    private let connectTimeout: TimeInterval

    public init(host: String, port: UInt16, timeout: TimeInterval = 10) {
        self.host = host
        self.port = port
        self.connectTimeout = timeout
    }

    private static let debug = ProcessInfo.processInfo.environment["ASTERIA_RTSP_DEBUG"] != nil

    /// One request = one connection. Opens fresh TCP (TCP_NODELAY), reads until reply frames.
    public func send(_ request: RTSPRequest) async throws -> RTSPResponse {
        let connection = try await connect()
        defer { connection.cancel() }

        let bytes = request.serialized()
        if Self.debug { print(">>> SENT \(request.method) (\(bytes.count)B):\n\(String(decoding: bytes, as: UTF8.self))") }
        try await send(bytes, over: connection)

        var framer = RTSPResponseFramer()
        while true {
            let chunk: (data: Data, endOfStream: Bool)
            do {
                chunk = try await receive(from: connection)
            } catch {
                if let response = framer.finish() { return response }
                throw error
            }
            if Self.debug {
                let text = String(decoding: chunk.data, as: UTF8.self)
                print("<<< RECV (\(chunk.data.count)B):\n\(text)")
            }
            if let response = try framer.ingest(chunk.data, endOfStream: chunk.endOfStream) {
                return response
            }
        }
    }

    /// Connect with retry: up to 5 attempts 500 ms apart (GFE may briefly refuse during session setup).
    private func connect() async throws -> NWConnection {
        let params = NetworkQoS.controlTCPParameters()

        var lastError: Error?
        for attempt in 0..<5 {
            let connection = NWConnection(host: NWEndpoint.Host(host),
                                          port: NWEndpoint.Port(rawValue: port)!, using: params)
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: cont.resume()
                        case .failed(let error): cont.resume(throwing: error)
                        case .cancelled: cont.resume(throwing: RTSPError.transport("cancelled"))
                        default: break
                        }
                    }
                    connection.start(queue: .global())
                }
                connection.stateUpdateHandler = nil
                return connection
            } catch {
                lastError = error
                connection.cancel()
                if attempt < 4 { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
        }
        throw lastError ?? RTSPError.transport("connect failed")
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func receive(
        from connection: NWConnection
    ) async throws -> (data: Data, endOfStream: Bool) {
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<(data: Data, endOfStream: Bool), Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1024
            ) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }
}
