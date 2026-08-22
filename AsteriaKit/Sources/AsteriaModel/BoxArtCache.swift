import Foundation

/// Per-host box-art byte cache; the disk impl persists, the in-memory fake backs tests.
public protocol BoxArtCache: Sendable {
    func image(host: String, appId: String) async -> Data?
    func store(_ data: Data, host: String, appId: String) async
    func removeAll(host: String) async
}

public enum BoxArtCacheKey {
    /// Filesystem-safe "<host>/<appId>" key; non-alphanumerics collapse to "_".
    public static func relativePath(host: String, appId: String) -> String {
        hostPrefix(host) + sanitize(appId)
    }

    public static func hostPrefix(_ host: String) -> String { sanitize(host) + "/" }

    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = String(String.UnicodeScalarView(s.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        return mapped.isEmpty ? "_" : mapped
    }
}

public actor InMemoryBoxArtCache: BoxArtCache {
    private var storage: [String: Data] = [:]
    public init() {}

    public func image(host: String, appId: String) -> Data? {
        storage[BoxArtCacheKey.relativePath(host: host, appId: appId)]
    }
    public func store(_ data: Data, host: String, appId: String) {
        storage[BoxArtCacheKey.relativePath(host: host, appId: appId)] = data
    }
    public func removeAll(host: String) {
        let prefix = BoxArtCacheKey.hostPrefix(host)
        storage = storage.filter { !$0.key.hasPrefix(prefix) }
    }
}

/// Box art as files under `<directory>/<host>/<appId>`; writes are atomic.
public struct DiskBoxArtCache: BoxArtCache {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Default location: `~/Library/Application Support/<subdirectory>`.
    public init(applicationSupportSubdirectory: String = "Asteria/BoxArt") throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        directory = base.appendingPathComponent(applicationSupportSubdirectory, isDirectory: true)
    }

    private func url(host: String, appId: String) -> URL {
        directory.appendingPathComponent(BoxArtCacheKey.relativePath(host: host, appId: appId))
    }

    public func image(host: String, appId: String) async -> Data? {
        try? Data(contentsOf: url(host: host, appId: appId))
    }

    public func store(_ data: Data, host: String, appId: String) async {
        let target = url(host: host, appId: appId)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
    }

    public func removeAll(host: String) async {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(BoxArtCacheKey.hostPrefix(host), isDirectory: true))
    }
}
