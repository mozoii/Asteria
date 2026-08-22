import AsteriaModel

public actor LibraryDocumentStore {
    public typealias Mutation = @Sendable (inout LibraryDocument) -> Void

    private let repository: any LibraryRepository
    private var tail: Task<Result<LibraryDocument, any Error>, Never>?

    public init(repository: any LibraryRepository) {
        self.repository = repository
    }

    public func snapshot() async throws -> LibraryDocument {
        guard let tail else { return try await repository.load() }
        switch await tail.value {
        case let .success(document): return document
        case .failure: return try await repository.load()
        }
    }

    public func update(_ mutation: @escaping Mutation) async throws -> LibraryDocument {
        let predecessor = tail
        let repository = self.repository
        let task = Task<Result<LibraryDocument, any Error>, Never> {
            do {
                var document = try await Self.baseDocument(
                    predecessor: predecessor,
                    repository: repository
                )
                mutation(&document)
                try await repository.save(document)
                return .success(document)
            } catch {
                return .failure(error)
            }
        }
        tail = task
        return try await task.value.get()
    }

    private static func baseDocument(
        predecessor: Task<Result<LibraryDocument, any Error>, Never>?,
        repository: any LibraryRepository
    ) async throws -> LibraryDocument {
        guard let predecessor else { return try await repository.load() }
        switch await predecessor.value {
        case let .success(document): return document
        case .failure: return try await repository.load()
        }
    }
}
