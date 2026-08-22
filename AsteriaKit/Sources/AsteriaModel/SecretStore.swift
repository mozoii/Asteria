import Foundation

/// Secure key→bytes storage. Live impl is the macOS Keychain; the in-memory fake backs tests.
public protocol SecretStore: Sendable {
    func data(forKey key: String) throws -> Data?
    func set(_ data: Data, forKey key: String) throws
    func removeValue(forKey key: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}

    public func data(forKey key: String) throws -> Data? {
        lock.withLock { items[key] }
    }
    public func set(_ data: Data, forKey key: String) throws {
        lock.withLock { items[key] = data }
    }
    public func removeValue(forKey key: String) throws {
        lock.withLock { _ = items.removeValue(forKey: key) }
    }
}
