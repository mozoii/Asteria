import SwiftUI
import AsteriaKit

/// "Choose your PC" — the shell's landing screen showing paired PCs sorted by availability.
struct HostPickerView: View {
    let store: HostListStore
    var appName = "Asteria"
    var onOpenSettings: () -> Void = {}
    var onSelect: (HostRecord) -> Void

    @State private var showingAdd = false
    @State private var manualText = ""
    @State private var renameTarget: HostRecord?
    @State private var renameText = ""
    @State private var cursor = DeckCursor<FocusTarget>()
    @StateObject private var nav = ControllerNavReader()

    private enum FocusTarget: Hashable, Sendable {
        case host(String)
        case add
        case settings
        case refresh
    }

    private var highlight: FocusTarget? { cursor.highlight }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            content
            ControllerHintBar(hints: [
                ControllerHint(glyph: .a, label: "Select"),
                ControllerHint(glyph: .y, label: "Add a PC"),
                ControllerHint(glyph: .symbol("arrow.clockwise"), label: "Refresh"),
            ])
        }
        .background(AsteriaTheme.background)
        .foregroundStyle(.white)
        .task {
            await store.load()
            if !isRunningInPreview { await store.refresh() }
        }
        .controllerNavigation(nav, focusFirst: focusFirstIfController, drain: drainNav, move: keyboardMove)
        .sheet(isPresented: $showingAdd) { addSheet }
        .sheet(item: $renameTarget) { renameSheet(for: $0) }
    }

    /// 2D nav: header (Refresh, Settings, Add) + one row per host; left/right in header, up/down between.
    private var navRows: [[FocusTarget]] {
        [[.refresh, .settings, .add]] + orderedHosts.map { [.host($0.id)] }
    }

    private func focusFirstIfController() {
        guard nav.isConnected else { return }
        focusFirst()
    }

    private func focusFirst() {
        cursor.focusFirst(navRows)
    }

    private func drainNav() {
        nav.drain(blocked: showingAdd || renameTarget != nil) { apply($0) }
    }

    /// Keyboard arrow/Return navigation, sharing the controller's directional model and the same guard.
    private func keyboardMove(_ dir: ControllerNavReader.Dir) {
        guard !showingAdd, renameTarget == nil else { return }
        if highlight == nil { focusFirst() } else { apply(dir) }
    }

    private func apply(_ dir: ControllerNavReader.Dir) {
        guard !navRows.isEmpty else { return }
        if let deckDir = dir.deckDirection {
            cursor.step(deckDir, rows: navRows)
            return
        }
        switch dir {
        case .activate:
            switch highlight {
            case let .host(id):
                if let h = orderedHosts.first(where: { $0.id == id }) { onSelect(h) }
            case .add:
                showingAdd = true
            case .settings: onOpenSettings()
            case .refresh: Task { await store.refresh() }
            case .none: break
            }
        case .back, .options, .reset, .prevSection, .nextSection:
            break   // home is the root screen — nothing to go back to
        case .up, .down, .left, .right: break   // handled via deckDirection above
        }
    }

    private var isFirstRun: Bool { !store.hosts.contains { $0.isPaired } }

    private var onlineCount: Int { store.hosts.filter { store.availability(for: $0) == .online }.count }

    private var orderedHosts: [HostRecord] {
        store.hosts.enumerated().sorted { lhs, rhs in
            let l = HostStatusStyle.rank(store.availability(for: lhs.element))
            let r = HostStatusStyle.rank(store.availability(for: rhs.element))
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isFirstRun ? "Welcome to \(appName)" : "Choose your PC").font(.title2.bold())
                if isFirstRun {
                    Text("Let's connect your gaming PC. Make sure Sunshine or Apollo is running on it, on the same network.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("\(onlineCount) of \(store.hosts.count) online").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isScanning { ProgressView().controlSize(.small) }
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").padding(6)
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .controllerFocusRing(highlight == .refresh, radius: 8)
            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape").padding(6)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .controllerFocusRing(highlight == .settings, radius: 8)
            Button { showingAdd = true } label: {
                Label("Add a PC", systemImage: "plus")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(AsteriaTheme.accent, in: .capsule)
            .controllerFocusRing(highlight == .add, radius: 18)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    @ViewBuilder private var content: some View {
        if store.hosts.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(orderedHosts.enumerated()), id: \.element.id) { index, host in
                        if index > 0 {
                            Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 74)
                        }
                        HostRow(host: host, availability: store.availability(for: host),
                                isFocused: highlight == .host(host.id)) {
                            onSelect(host)
                        }
                        .contextMenu {
                            Button("Rename") { beginRename(host) }
                            Button("Forget this PC", role: .destructive) { Task { await store.forget(host) } }
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 74)
                    AddHostRow {
                        showingAdd = true
                    }
                }
                .background(AsteriaTheme.surface, in: .rect(cornerRadius: AsteriaTheme.cardCorner))
                .overlay {
                    RoundedRectangle(cornerRadius: AsteriaTheme.cardCorner, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
                .padding(28)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer").font(.system(size: 56)).foregroundStyle(.secondary)
            Text(store.isScanning ? "Looking for PCs on your network…" : "No PCs found yet")
                .font(.title3.weight(.medium))
            Text("Make sure Sunshine or Apollo is running on your PC, then refresh, or add it by address.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button { showingAdd = true } label: {
                Label("Add a PC", systemImage: "plus")
            }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a PC").font(.title2.bold())
            Text("Enter the PC's IP address or hostname.").font(.subheadline).foregroundStyle(.secondary)
            TextField("192.168.1.20 or my-pc.local", text: $manualText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitManual() }
            HStack {
                Spacer()
                Button("Cancel") { showingAdd = false; manualText = "" }
                Button("Add") { submitManual() }
                    .buttonStyle(.borderedProminent)
                    .disabled(ManualHostAddress.normalize(manualText) == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func submitManual() {
        let text = manualText
        guard ManualHostAddress.normalize(text) != nil else { return }
        showingAdd = false
        manualText = ""
        Task { await store.addManualHost(text) }
    }

    private func renameSheet(for host: HostRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename PC").font(.title2.bold())
            Text("Choose a name for this PC. Leave it blank to use the default name.")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField(host.name, text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitRename(host) }
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil; renameText = "" }
                Button("Save") { submitRename(host) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func beginRename(_ host: HostRecord) {
        renameText = host.customName ?? ""
        renameTarget = host
    }

    private func submitRename(_ host: HostRecord) {
        let text = renameText
        renameTarget = nil
        renameText = ""
        Task { await store.renameHost(host, to: text) }
    }
}

/// Host row with focus edge-bar accent.
private struct HostRow: View {
    let host: HostRecord
    let availability: HostAvailability
    let isFocused: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AsteriaTheme.accent)
                    .frame(width: 3, height: isFocused ? 34 : 0)
                    .padding(.leading, 10)
                HStack(spacing: 14) {
                    DeviceBadge(statusColor: HostStatusStyle.color(availability))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(host.displayName).font(.headline).lineLimit(1)
                            if host.isPaired {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark")
                                    Text("Paired")
                                }
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(AsteriaTheme.accent)
                                .help("Paired")
                            }
                        }
                        Text(host.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HostIdentityMetadataView(
                            hostSoftware: host.hostSoftware,
                            fingerprint: host.clientFingerprint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    AvailabilityBadge(availability: availability)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isFocused ? AsteriaTheme.accent : .secondary)
                        .offset(x: isFocused ? 3 : 0)
                }
                .padding(.leading, 28)
                .padding(.trailing, 20)
            }
            .frame(height: 78)
            .frame(maxWidth: .infinity)
            .background(isFocused ? AsteriaTheme.surfaceFocused : .clear)
            .animation(.spring(response: 0.28, dampingFraction: 0.74), value: isFocused)
        }
        .buttonStyle(.plain)
    }

}

/// Device badge with availability-color glow motif.
private struct DeviceBadge: View {
    let statusColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AsteriaTheme.surfaceFocused)
                .overlay { RadialGradient(colors: [statusColor.opacity(0.45), .clear],
                                          center: .center, startRadius: 0, endRadius: 26) }
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .frame(width: 42, height: 42)
            Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.white.opacity(0.9))
        }
    }
}

private struct AddHostRow: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(AsteriaTheme.accent.opacity(0.55))
                        .frame(width: 42, height: 42)
                    Image(systemName: "plus")
                        .font(.headline).foregroundStyle(AsteriaTheme.accent)
                }
                Text("Add a PC")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.leading, 28).padding(.trailing, 20)
            .frame(height: 64)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// Status badge with pulse animation on online hosts.
private struct AvailabilityBadge: View {
    let availability: HostAvailability
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(pulse ? 0.8 : 0.0), radius: 4)
            Text(HostStatusStyle.label(availability)).font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(AsteriaTheme.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .onChange(of: availability, initial: true) { _, newAvailability in
            let animation: Animation? = newAvailability == .online
                ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                : nil
            withAnimation(animation) { pulse = newAvailability == .online }
        }
    }

    private var color: Color { HostStatusStyle.color(availability) }
}

private enum HostStatusStyle {
    static func rank(_ a: HostAvailability) -> Int {
        switch a {
        case .online: return 0
        case .busy: return 1
        case .unknown: return 2
        case .offline: return 3
        }
    }

    static func color(_ a: HostAvailability) -> Color {
        switch a {
        case .online: return .green
        case .busy: return .orange
        case .offline: return .gray
        case .unknown: return .gray.opacity(0.5)
        }
    }

    static func label(_ a: HostAvailability) -> String {
        switch a {
        case .online: return "Online"
        case .busy: return "In use"
        case .offline: return "Offline"
        case .unknown: return "Checking…"
        }
    }
}

#if DEBUG
enum HostPickerPreviewData {
    static let hosts: [HostRecord] = [
        HostRecord(id: "uid-online", name: "Living Room PC", address: "192.168.1.20", isPaired: true),
        HostRecord(id: "uid-busy", name: "Office Desktop", address: "192.168.1.21", isPaired: true),
        HostRecord(id: "uid-offline", name: "Bedroom Rig", address: "192.168.1.22", isPaired: true),
        HostRecord(id: "uid-new", name: "DESKTOP-AB12CD", customName: "Garage Streamer",
                   address: "192.168.1.23", isPaired: false),
    ]
    static let availability: [String: HostAvailability] = [
        "uid-online": .online, "uid-busy": .busy, "uid-offline": .offline, "uid-new": .online,
    ]
}

#Preview("Host picker: populated") {
    HostPickerView(
        store: .preview(hosts: HostPickerPreviewData.hosts, availability: HostPickerPreviewData.availability),
        onSelect: { _ in })
    .frame(width: 900, height: 640)
}

#Preview("Host picker: empty") {
    HostPickerView(store: .preview(hosts: []), onSelect: { _ in })
        .frame(width: 900, height: 640)
}
#endif
