import Foundation
import Testing
@testable import AsteriaModel

@Suite("Secret store")
struct SecretStoreTests {
    @Test("In-memory secret store sets, reads, and removes")
    func inMemoryCRUD() throws {
        let store = InMemorySecretStore()
        #expect(try store.data(forKey: "k") == nil)
        try store.set(Data([1, 2, 3]), forKey: "k")
        #expect(try store.data(forKey: "k") == Data([1, 2, 3]))
        try store.set(Data([9]), forKey: "k")
        #expect(try store.data(forKey: "k") == Data([9]))
        try store.removeValue(forKey: "k")
        #expect(try store.data(forKey: "k") == nil)
    }
}
