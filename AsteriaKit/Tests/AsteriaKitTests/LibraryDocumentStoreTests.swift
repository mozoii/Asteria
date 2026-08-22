import Testing
@testable import AsteriaKit

@Suite("Library document store")
struct LibraryDocumentStoreTests {
    @Test("concurrent mutations preserve both committed changes")
    func concurrentMutations() async throws {
        let repository = InMemoryLibraryRepository()
        let store = LibraryDocumentStore(repository: repository)
        let host = HostRecord(id: "living-room", name: "Living Room", address: "192.168.1.20")

        async let addHost = store.update { document in
            document.hosts.append(host)
        }
        async let finishOnboarding = store.update { document in
            document.isOnboardingComplete = true
        }
        _ = try await (addHost, finishOnboarding)

        let saved = try await store.snapshot()
        #expect(saved.hosts == [host])
        #expect(saved.isOnboardingComplete)
    }

    @Test("failed mutation is not published and a later mutation can save")
    func failedMutationDoesNotPublish() async throws {
        let repository = FailOnceLibraryRepository()
        let store = LibraryDocumentStore(repository: repository)

        await #expect(throws: TestFailure.self) {
            try await store.update { document in
                document.isOnboardingComplete = true
            }
        }
        #expect(try await !store.snapshot().isOnboardingComplete)

        let saved = try await store.update { document in
            document.isOnboardingComplete = true
        }
        #expect(saved.isOnboardingComplete)
        #expect(try await store.snapshot().isOnboardingComplete)
    }
}

private enum TestFailure: Error {
    case save
}

private actor FailOnceLibraryRepository: LibraryRepository {
    private var document = LibraryDocument.empty
    private var shouldFail = true

    func load() async throws -> LibraryDocument {
        document
    }

    func save(_ document: LibraryDocument) async throws {
        if shouldFail {
            shouldFail = false
            throw TestFailure.save
        }
        self.document = document
    }
}
