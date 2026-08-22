import Foundation
import Observation
import AsteriaKit

/// Library view-model for one paired host: fetches applist + running state, composes entries,
/// and resolves box art through a disk cache (title-card fallback handled by the view).
@MainActor
@Observable
final class AppLibraryStore {
    let host: HostRecord
    private(set) var entries: [AppLibraryEntry] = []
    var searchText = ""
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var requiresPairingAgain = false

    private let identities: ClientIdentityVault
    private let boxArt: any BoxArtCache
    private var artData: [String: Data] = [:]

    init(host: HostRecord,
         identities: ClientIdentityVault = .appKeychain,
         boxArt: any BoxArtCache = (try? DiskBoxArtCache()) ?? InMemoryBoxArtCache()) {
        self.host = host
        self.identities = identities
        self.boxArt = boxArt
    }

    var visibleEntries: [AppLibraryEntry] { AppLibrary.filter(entries, query: searchText) }
    var runningEntry: AppLibraryEntry? { entries.first(where: \.isRunning) }

    func art(for entry: AppLibraryEntry) -> Data? { artData[entry.appId] }

    /// Refetch applist + running state; `forceArt` discards cached art and re-downloads it.
    func refresh(forceArt: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        requiresPairingAgain = false
        do {
            let access = try makeAccess()
            let info = try? await access.serverInfo()
            let apps = try await access.apps()
            let runningGame = info?.currentGame ?? 0
            entries = AppLibrary.compose(apps: apps.map { (appId: $0.id, title: $0.title) },
                                         runningAppId: runningGame != 0 ? String(runningGame) : nil)
            if forceArt { await boxArt.removeAll(host: host.id) }
            await loadArt(access: access, forceArt: forceArt)
        } catch {
            requiresPairingAgain = (error as? PairingError) == .serverVerificationFailed
            errorMessage = Self.message(for: error)
        }
    }

    /// Quit whatever is running on the host, then refresh.
    func quitRunningApp() async {
        guard let access = try? makeAccess() else { return }
        _ = try? await access.cancel()
        await refresh()
    }

    private func loadArt(access: PairedHostAccess, forceArt: Bool) async {
        for entry in entries {
            if !forceArt, let cached = await boxArt.image(host: host.id, appId: entry.appId) {
                artData[entry.appId] = cached
                continue
            }
            guard let data = try? await access.boxArt(appID: entry.appId),
                  Self.isImage(data) else { continue }
            await boxArt.store(data, host: host.id, appId: entry.appId)
            artData[entry.appId] = data
        }
    }

    private func makeAccess() throws -> PairedHostAccess {
        try PairedHostAccess(profile: host, identities: identities)
    }

    static func isImage(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(3))
        if head.count >= 2, head[0] == 0x89, head[1] == 0x50 { return true }
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return true }
        return false
    }

    static func message(for error: Error) -> String {
        if error is PairingError { return PairingError.userMessage(for: error) }
        return "Couldn't load the library: \(error.localizedDescription)"
    }

    #if DEBUG
    static func preview(host: HostRecord, entries: [AppLibraryEntry], art: [String: Data] = [:]) -> AppLibraryStore {
        let store = AppLibraryStore(host: host, boxArt: InMemoryBoxArtCache())
        store.entries = entries
        store.artData = art
        return store
    }
    #endif
}
