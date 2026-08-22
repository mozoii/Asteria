/// Product-level progress for establishing a GameStream connection.
public enum ConnectionPhase: Sendable, Equatable {
    case idle
    case preparingSession
    case negotiatingSession
    case openingMediaPaths
    case streaming
}
