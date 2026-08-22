import Foundation

/// A parsed SDP media description (`m=<type> <port> <proto> <formats...>`).
public struct SDPMediaDescription: Sendable, Equatable {
    public let type: String       // "video", "audio", "control"
    public let port: Int
    public let proto: String
    public let formats: [String]
}

/// Minimal SDP parser for DESCRIBE response. Exposes media sections and `a=name:value` attributes.
public struct SessionDescription: Sendable {
    /// Ordered (type, value) lines from SDP.
    public let lines: [(Character, String)]

    public init?(parsing text: String) {
        var parsed: [(Character, String)] = []
        for line in text.components(separatedBy: .newlines) {
            if line.isEmpty { continue }
            guard line.count >= 2, line[line.index(line.startIndex, offsetBy: 1)] == "=" else { continue }
            parsed.append((line.first!, String(line.dropFirst(2))))
        }
        guard parsed.first?.0 == "v" else { return nil }
        self.lines = parsed
    }

    public var mediaDescriptions: [SDPMediaDescription] {
        lines.filter { $0.0 == "m" }.compactMap { (_, value) in
            let parts = value.split(separator: " ").map(String.init)
            guard parts.count >= 3, let port = Int(parts[1]) else { return nil }
            return SDPMediaDescription(type: parts[0], port: port, proto: parts[2], formats: Array(parts[3...]))
        }
    }

    /// First a=name:value attribute matching the given name.
    public func attribute(_ name: String) -> String? {
        for (type, value) in lines where type == "a" {
            guard let colon = value.firstIndex(of: ":") else { continue }
            if String(value[..<colon]) == name {
                return String(value[value.index(after: colon)...])
            }
        }
        return nil
    }

    /// Whether host advertises reference-frame invalidation (x-nv-video[0].refPicInvalidation attribute).
    public var advertisesReferenceFrameInvalidation: Bool {
        let name = "x-nv-video[0].refPicInvalidation"
        return lines.contains { $0.0 == "a" && $0.1.hasPrefix(name) }
    }
}
