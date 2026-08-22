import Foundation
import Testing
@testable import AsteriaModel

@Suite("Box-art cache")
struct BoxArtCacheTests {
    @Test("Key sanitizes host and appId into a safe relative path")
    func keySanitization() {
        #expect(BoxArtCacheKey.relativePath(host: "uid-AB12", appId: "1639965107") == "uid-AB12/1639965107")
        #expect(BoxArtCacheKey.relativePath(host: "../etc", appId: "a/b") == ".._etc/a_b")
        #expect(BoxArtCacheKey.hostPrefix("uid 1") == "uid_1/")
    }

    @Test("In-memory cache round-trips and clears per host")
    func inMemoryRoundTrip() async {
        let cache = InMemoryBoxArtCache()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        await cache.store(png, host: "h1", appId: "1")
        await cache.store(png, host: "h2", appId: "1")
        #expect(await cache.image(host: "h1", appId: "1") == png)
        #expect(await cache.image(host: "h1", appId: "2") == nil)

        await cache.removeAll(host: "h1")
        #expect(await cache.image(host: "h1", appId: "1") == nil)
        #expect(await cache.image(host: "h2", appId: "1") == png)
    }

    @Test("Disk cache persists bytes and clears a host subtree")
    func diskRoundTrip() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asteria-boxart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskBoxArtCache(directory: dir)
        let bytes = Data([0x01, 0x02, 0x03, 0x04])

        await cache.store(bytes, host: "h1", appId: "42")
        #expect(await cache.image(host: "h1", appId: "42") == bytes)
        #expect(await cache.image(host: "h1", appId: "99") == nil)

        await cache.removeAll(host: "h1")
        #expect(await cache.image(host: "h1", appId: "42") == nil)
    }
}
