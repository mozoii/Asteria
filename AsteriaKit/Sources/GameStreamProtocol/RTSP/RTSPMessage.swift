import Foundation

/// RTSP/1.0 request. CSeq and Content-Length are automatic.
public struct RTSPRequest: Sendable {
    public var method: String
    public var uri: String
    public var cseq: Int
    public var headers: [(String, String)]
    public var body: Data?

    public init(method: String, uri: String, cseq: Int, headers: [(String, String)] = [], body: Data? = nil) {
        self.method = method
        self.uri = uri
        self.cseq = cseq
        self.headers = headers
        self.body = body
    }

    public func serialized() -> Data {
        var text = "\(method) \(uri) RTSP/1.0\r\n"
        text += "CSeq: \(cseq)\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        if let body { text += "Content-Length: \(body.count)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body { data.append(body) }
        return data
    }
}

/// Parsed RTSP/1.0 response.
public struct RTSPResponse: Sendable {
    public let statusCode: Int
    public let reason: String
    public let cseq: Int?
    public let body: Data
    private let headerMap: [String: String]

    public func headerValue(_ name: String) -> String? { headerMap[name.lowercased()] }

    public init?(parsing data: Data) {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: sep) else { return nil }
        let headerText = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }

        // "RTSP/1.0 200 OK"
        let statusParts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("RTSP/"), let code = Int(statusParts[1]) else {
            return nil
        }
        self.statusCode = code
        self.reason = statusParts.count >= 3 ? statusParts[2] : ""

        lines.removeFirst()
        var map: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            map[key] = value
        }
        self.headerMap = map
        self.cseq = map["cseq"].flatMap { Int($0) }
        self.body = data.subdata(in: range.upperBound..<data.endIndex)
    }
}
