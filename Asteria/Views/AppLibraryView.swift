import SwiftUI
import AppKit
import AsteriaKit

/// Cover-art library for a paired host: searchable 2:3 card grid with running badge and per-app options.
struct AppLibraryView: View {
    let store: AppLibraryStore
    var onLaunch: (AppLibraryEntry) -> Void
    var onOpenSettings: () -> Void = {}
    var onBack: () -> Void
    var onPairAgain: () -> Void = {}
    /// Bumped by the shell when a stream ends, to refresh once so the running badge reflects the host.
    var refreshToken: Int = 0

    /// How often the library re-polls the host for applist + running state while it's on screen.
    private static let pollInterval: Duration = .seconds(30)

    @State private var confirmSwitchTo: AppLibraryEntry?
    @State private var appOptions: AppLibraryEntry?
    @State private var cursor = DeckCursor<LibFocus>()
    @StateObject private var nav = ControllerNavReader()
    /// Live column count of the adaptive grid, measured from its width — drives true 2D card navigation.
    @State private var gridCols = 1

    private enum LibFocus: Hashable, Sendable {
        case app(String)
        case back, refresh, settings
    }

    private var highlight: LibFocus? { cursor.highlight }

    private static let gridMin: CGFloat = 150
    private static let gridSpacing: CGFloat = 22
    private let columns = [GridItem(.adaptive(minimum: gridMin, maximum: 180), spacing: gridSpacing)]

    private func gridColumns(for width: CGFloat) -> Int {
        max(1, Int((width + Self.gridSpacing) / (Self.gridMin + Self.gridSpacing)))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            content
            ControllerHintBar(hints: [
                ControllerHint(glyph: .a, label: "Play"),
                ControllerHint(glyph: .x, label: "Options"),
                ControllerHint(glyph: .b, label: "Back"),
                ControllerHint(glyph: .symbol("arrow.clockwise"), label: "Refresh"),
            ])
        }
        .background(AsteriaTheme.background)
        .foregroundStyle(.white)
        .task {
            guard !isRunningInPreview else { return }
            await store.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { break }
                await store.refresh()
            }
        }
        .onChange(of: refreshToken) { _, _ in
            if !isRunningInPreview { Task { await store.refresh() } }
        }
        .controllerNavigation(nav, focusFirst: focusFirstIfController, drain: drainNav, move: keyboardMove)
        .onExitCommand { onBack() }
        .confirmationDialog("Quit current game?", isPresented: confirmBinding, presenting: confirmSwitchTo) { target in
            Button("Quit & play \(target.title)", role: .destructive) {
                Task { await store.quitRunningApp(); onLaunch(target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("\(store.runningEntry?.title ?? "A game") is running. Starting a game ends that session. Unsaved progress may be lost.")
        }
        .confirmationDialog(appOptions?.title ?? "App", isPresented: appOptionsBinding, presenting: appOptions) { entry in
            if entry.isRunning {
                Button("Resume") { primaryAction(entry) }
                Button("Quit app", role: .destructive) { Task { await store.quitRunningApp() } }
            } else {
                Button("Play") { primaryAction(entry) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var appOptionsBinding: Binding<Bool> {
        Binding(get: { appOptions != nil }, set: { if !$0 { appOptions = nil } })
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { onBack() } label: { Label("PCs", systemImage: "chevron.left").padding(4) }
                .buttonStyle(.plain)
                .controllerFocusRing(highlight == .back, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.host.displayName).font(.title2.bold()).lineLimit(1)
                HStack(spacing: 4) {
                    HostIdentityMetadataView(
                        hostSoftware: store.host.hostSoftware,
                        fingerprint: store.host.clientFingerprint)
                    Text("• \(store.entries.count) apps")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            searchField
            if store.isLoading { ProgressView().controlSize(.small) }
            Button { Task { await store.refresh(forceArt: true) } } label: { Image(systemName: "arrow.clockwise").padding(6) }
                .buttonStyle(.plain).help("Refresh apps and box art")
                .controllerFocusRing(highlight == .refresh, radius: 8)
            Button { onOpenSettings() } label: { Image(systemName: "gearshape").padding(6) }
                .buttonStyle(.plain).help("Settings for this PC")
                .controllerFocusRing(highlight == .settings, radius: 8)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps", text: Binding(get: { store.searchText }, set: { store.searchText = $0 }))
                .textFieldStyle(.plain).frame(width: 180)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(AsteriaTheme.surface, in: .rect(cornerRadius: 9))
    }

    @ViewBuilder private var content: some View {
        if let error = store.errorMessage,
           store.entries.isEmpty || store.requiresPairingAgain {
            message(icon: "exclamationmark.triangle", title: "Couldn't load apps", detail: error,
                    showPairAgain: store.requiresPairingAgain)
        } else if store.entries.isEmpty {
            message(icon: store.isLoading ? "hourglass" : "square.grid.2x2",
                    title: store.isLoading ? "Loading apps…" : "No apps found",
                    detail: "This PC isn't advertising any apps yet. Check Sunshine/Apollo, then refresh.")
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(store.visibleEntries) { entry in
                            AppCard(entry: entry, art: store.art(for: entry)) { primaryAction(entry) }
                                .id(entry.appId)
                                .controllerFocusRing(highlight == .app(entry.appId), radius: AsteriaTheme.cardCorner)
                                .contextMenu { menu(for: entry) }
                        }
                    }
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { gridCols = gridColumns(for: proxy.size.width) }
                            .onChange(of: proxy.size.width) { _, w in gridCols = gridColumns(for: w) }
                    })
                    .padding(28)
                }
                // Scroll the highlighted card into view as controller/keyboard navigation moves below the fold.
                .onChange(of: highlight) { _, h in
                    guard case let .app(id)? = h else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { scroller.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder private func menu(for entry: AppLibraryEntry) -> some View {
        if entry.isRunning {
            Button("Resume") { primaryAction(entry) }
            Button("Quit app", role: .destructive) { Task { await store.quitRunningApp() } }
        } else {
            Button("Play") { primaryAction(entry) }
        }
    }

    /// The running app resumes silently; a different app confirms first (starting it quits the current session).
    private func primaryAction(_ entry: AppLibraryEntry) {
        if entry.isRunning {
            onLaunch(entry)
        } else if store.runningEntry != nil {
            confirmSwitchTo = entry
        } else {
            onLaunch(entry)
        }
    }

    /// 2D nav: header (Back, Refresh, Settings) + app grid; left/right moves cards, up/down moves rows.
    private var navRows: [[LibFocus]] {
        let cards = store.visibleEntries.map { LibFocus.app($0.appId) }
        let cols = max(1, gridCols)
        var rows: [[LibFocus]] = [[.back, .refresh, .settings]]
        var i = 0
        while i < cards.count { rows.append(Array(cards[i..<min(i + cols, cards.count)])); i += cols }
        return rows
    }

    private func focusFirstIfController() {
        guard nav.isConnected else { return }
        focusFirst()
    }

    private func focusFirst() {
        cursor.focusFirst(navRows)
    }

    private var navBlocked: Bool { confirmSwitchTo != nil || appOptions != nil }

    private func drainNav() {
        nav.drain(blocked: navBlocked) { apply($0) }
    }

    /// Keyboard arrow/Return navigation, sharing the controller's directional model and the same guards.
    private func keyboardMove(_ dir: ControllerNavReader.Dir) {
        guard !navBlocked else { return }
        if highlight == nil { focusFirst() } else { apply(dir) }
    }

    private func apply(_ dir: ControllerNavReader.Dir) {
        guard !navRows.isEmpty else { return }
        if let deckDir = dir.deckDirection {
            cursor.step(deckDir, rows: navRows)
            return
        }
        switch dir {
        case .options:   // X opens options (system can't open our dialog)
            if case let .app(id)? = highlight, let e = store.visibleEntries.first(where: { $0.appId == id }) { appOptions = e }
        case .back: onBack()
        case .activate:
            switch highlight {
            case let .app(id): if let e = store.visibleEntries.first(where: { $0.appId == id }) { primaryAction(e) }
            case .back: onBack()
            case .refresh: Task { await store.refresh(forceArt: true) }
            case .settings: onOpenSettings()
            case .none: break
            }
        case .reset, .prevSection, .nextSection: break
        case .up, .down, .left, .right: break   // handled via deckDirection above
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirmSwitchTo != nil }, set: { if !$0 { confirmSwitchTo = nil } })
    }

    private func message(
        icon: String,
        title: String,
        detail: String,
        showPairAgain: Bool = false
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 50)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.medium))
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if showPairAgain {
                Button("Pair Again", action: onPairAgain)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One 2:3 cover card: box art (aspect-fill) or a generated title card, with a bottom title strip.
private struct AppCard: View {
    let entry: AppLibraryEntry
    let art: Data?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // Color.clear fixes a concrete 2:3 cell so the badge/title overlays can't stretch the card height.
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { cover.scaledToFill() }
                .clipShape(.rect(cornerRadius: AsteriaTheme.cardCorner))
                .overlay(alignment: .bottom) { titleStrip }
                .overlay(alignment: .topTrailing) { if entry.isRunning { runningBadge } }
                .clipShape(.rect(cornerRadius: AsteriaTheme.cardCorner))
                .contentShape(.rect(cornerRadius: AsteriaTheme.cardCorner))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var cover: some View {
        if let art, let image = NSImage(data: art) {
            Image(nsImage: image).resizable()
        } else {
            TitleCardArt(title: entry.title, isDesktop: entry.isDesktop)
        }
    }

    private var titleStrip: some View {
        Text(entry.title)
            .font(.caption.weight(.semibold)).lineLimit(2).foregroundStyle(.white)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
    }

    private var runningBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("RUNNING").font(.system(.caption2, design: .rounded).weight(.heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.black.opacity(0.72), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .shadow(radius: 3)
        .padding(8)
    }
}

/// Generated fallback art for apps with no box art: deterministic gradient + icon + title.
struct TitleCardArt: View {
    let title: String
    var isDesktop = false

    var body: some View {
        ZStack {
            LinearGradient(colors: Self.colors(for: title), startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Image(systemName: isDesktop ? "menubar.dock.rectangle" : "gamecontroller.fill")
                    .font(.system(size: 34)).opacity(0.55)
                Text(title).font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 12)
            }
            .foregroundStyle(.white.opacity(0.92))
        }
    }

    /// Stable (process-independent) hue from the title so a card keeps its color across launches.
    private static func colors(for title: String) -> [Color] {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in title.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let hue = Double(hash % 360) / 360
        return [Color(hue: hue, saturation: 0.55, brightness: 0.5),
                Color(hue: hue, saturation: 0.7, brightness: 0.28)]
    }
}

#if DEBUG
enum AppLibraryPreviewData {
    static let host = HostRecord(id: "uid-online", name: "Living Room PC", address: "192.168.1.20", isPaired: true)

    static let entries: [AppLibraryEntry] = [
        AppLibraryEntry(appId: "3", title: "Hades", isRunning: true),
        AppLibraryEntry(appId: "2", title: "Cyberpunk 2077"),
        AppLibraryEntry(appId: "5", title: "Hollow Knight: Silksong"),
        AppLibraryEntry(appId: "1", title: "Desktop", isDesktop: true),
        AppLibraryEntry(appId: "4", title: "Steam Big Picture"),
        AppLibraryEntry(appId: "6", title: "Elden Ring"),
    ]

    /// A solid-color PNG so one card exercises the real box-art (aspect-fill) path.
    static func swatchPNG(_ color: NSColor) -> Data {
        let size = NSSize(width: 60, height: 90)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill(); NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    static let art: [String: Data] = ["2": swatchPNG(.systemPurple), "6": swatchPNG(.systemBrown)]
}

#Preview("Library: populated") {
    AppLibraryView(
        store: .preview(host: AppLibraryPreviewData.host,
                        entries: AppLibraryPreviewData.entries, art: AppLibraryPreviewData.art),
        onLaunch: { _ in }, onBack: {})
    .frame(width: 900, height: 640)
}

#Preview("Library: empty") {
    AppLibraryView(store: .preview(host: AppLibraryPreviewData.host, entries: []),
                   onLaunch: { _ in }, onBack: {})
    .frame(width: 900, height: 640)
}

#Preview("Title-card fallback") {
    HStack(spacing: 16) {
        TitleCardArt(title: "Hollow Knight: Silksong")
        TitleCardArt(title: "Desktop", isDesktop: true)
        TitleCardArt(title: "Elden Ring")
    }
    .frame(height: 240).padding().background(AsteriaTheme.background)
}
#endif
