import Foundation

/// Validated lowercase SHA-256 certificate fingerprint.
public struct ClientFingerprint: RawRepresentable, Codable, Hashable, Sendable,
                                 CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 64,
              rawValue == rawValue.lowercased(),
              rawValue.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.rawValue = rawValue
    }

    public init?(sha256Digest: some Sequence<UInt8>) {
        let bytes = Array(sha256Digest)
        guard bytes.count == 32 else { return nil }
        rawValue = bytes.map { String(format: "%02x", $0) }.joined()
    }

    public var shortDisplay: String { String(rawValue.prefix(8)).uppercased() }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let fingerprint = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription:
                        "Client fingerprint must be 64 lowercase hexadecimal characters."))
        }
        self = fingerprint
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
