import Foundation

/// The persisted app state: global settings, the host roster, and global input preferences. `schemaVersion` gates future migrations.
public struct LibraryDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var globalSettings: StreamSettings
    public var hosts: [HostRecord]
    public var inputPreferences: InputPreferences
    /// Global customization of the in-stream stats overlay.
    public var overlayPreferences: OverlayPreferences
    /// Set once the first-run setup flow finishes; gates whether onboarding is shown on launch.
    public var isOnboardingComplete: Bool
    /// Ids/addresses of hosts the user chose "Forget this PC" for; persisted so they stay gone across launches.
    public var forgottenHostKeys: [String]

    /// Current on-disk schema. Bump and add a migration in `init(from:)` when new fields ship.
    public static let currentSchemaVersion = 3

    public init(schemaVersion: Int = 3, globalSettings: StreamSettings = .defaults, hosts: [HostRecord] = [],
                inputPreferences: InputPreferences = .defaults,
                overlayPreferences: OverlayPreferences = .defaults, isOnboardingComplete: Bool = false,
                forgottenHostKeys: [String] = []) {
        self.schemaVersion = schemaVersion
        self.globalSettings = globalSettings
        self.hosts = hosts
        self.inputPreferences = inputPreferences
        self.overlayPreferences = overlayPreferences
        self.isOnboardingComplete = isOnboardingComplete
        self.forgottenHostKeys = forgottenHostKeys
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, globalSettings, hosts, inputPreferences, overlayPreferences, isOnboardingComplete
        case forgottenHostKeys
    }

    // Tolerant decode so a document written before a field existed loads with that field's default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        globalSettings = try c.decodeIfPresent(StreamSettings.self, forKey: .globalSettings) ?? .defaults
        hosts = try c.decodeIfPresent([HostRecord].self, forKey: .hosts) ?? []
        inputPreferences = try c.decodeIfPresent(InputPreferences.self, forKey: .inputPreferences) ?? .defaults
        overlayPreferences = try c.decodeIfPresent(OverlayPreferences.self, forKey: .overlayPreferences) ?? .defaults
        isOnboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .isOnboardingComplete) ?? false
        forgottenHostKeys = try c.decodeIfPresent([String].self, forKey: .forgottenHostKeys) ?? []
        let writtenVersion = schemaVersion
        // v1→v2: documents saved before the mute action existed have no mute chords; backfill defaults once.
        // Only v1 (pre-mute) documents need this — a v2 doc that omits a chord means "unbound", so it must not backfill.
        if writtenVersion < 2 {
            inputPreferences.keybindings = inputPreferences.keybindings.fillingMissingDefaults()
        }
        // Every decode re-stamps to the current on-disk schema (v2→v3 adds forgottenHostKeys, defaulted above).
        schemaVersion = Self.currentSchemaVersion
    }

    public static let empty = LibraryDocument()

    /// Replace the host with a matching id, or append it.
    public mutating func upsertHost(_ host: HostRecord) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
    }
}

/// Load/save the library document. Live impl persists JSON; the in-memory fake backs tests.
public protocol LibraryRepository: Sendable {
    func load() async throws -> LibraryDocument
    func save(_ document: LibraryDocument) async throws
}

public actor InMemoryLibraryRepository: LibraryRepository {
    private var document: LibraryDocument?
    public init(_ initial: LibraryDocument? = nil) { document = initial }
    public func load() async throws -> LibraryDocument { document ?? .empty }
    public func save(_ document: LibraryDocument) async throws { self.document = document }
}

/// JSON-on-disk repository; missing file reads as `.empty`, writes are atomic.
public struct JSONFileLibraryRepository: LibraryRepository {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// Default location: `~/Library/Application Support/<subdirectory>/<fileName>`.
    public init(applicationSupportSubdirectory: String = "Asteria", fileName: String = "library.json") throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        fileURL = base.appendingPathComponent(applicationSupportSubdirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public func load() async throws -> LibraryDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode(LibraryDocument.self, from: data)
    }

    public func save(_ document: LibraryDocument) async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try Self.encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
