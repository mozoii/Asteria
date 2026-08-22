import SwiftUI
import AsteriaModel

/// App-side glue over the repo-hosted changelog: runtime facts and the auto-present decision.
enum WhatsNew {
    private static let lastSeenKey = "whatsNewLastSeenVersion"

    /// Release notes live as `docs/changelogs/<version>.json` in the repo and are
    /// fetched at runtime, so they can be edited without shipping a new build.
    static let changelogBaseURL = URL(string:
        "https://raw.githubusercontent.com/mozoii/Asteria/main/docs/changelogs")!

    static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static func changelogURL(for version: String) -> URL {
        changelogBaseURL.appendingPathComponent("\(version).json")
    }

    /// This version's notes, or nil when no matching file exists (What's New stays off)
    /// or only an offline cached copy of a different version is available.
    static func currentChangelog() async -> ReleaseEntry? {
        let url = changelogURL(for: marketingVersion)
        if let (data, response) = try? await URLSession.shared.data(from: url),
           let http = response as? HTTPURLResponse {
            if http.statusCode == 200, let entry = try? ReleaseEntry(data: data) {
                try? data.write(to: cacheURL, options: .atomic)
                return entry
            }
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }
        guard let data = try? Data(contentsOf: cacheURL),
              let entry = try? ReleaseEntry(data: data),
              entry.version == marketingVersion else { return nil }
        return entry
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Asteria", isDirectory: true)
            .appendingPathComponent("changelog-cache.json")
    }

    /// Forces the sheet every launch, bypassing onboarding (a dev/test aid).
    static var forceShowOverride: Bool {
        WhatsNewOverride(environment: ProcessInfo.processInfo.environment) == .forceShow
    }

    static func autoPresentDecision(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    defaults: UserDefaults = .standard) -> Bool {
        WhatsNewDecision.shouldPresent(current: marketingVersion,
                                       lastSeen: defaults.string(forKey: lastSeenKey),
                                       override: WhatsNewOverride(environment: environment))
    }

    /// Presents only when the version changed *and* notes exist for it; a missing
    /// changelog file silently disables What's New for that version.
    static func shouldPresent(environment: [String: String] = ProcessInfo.processInfo.environment,
                              defaults: UserDefaults = .standard) async -> Bool {
        guard autoPresentDecision(environment: environment, defaults: defaults) else { return false }
        return await currentChangelog() != nil
    }
    /// First install: adopt the current version silently so the sheet doesn't fire on a version never run.
    static func recordSeenIfNeeded(defaults: UserDefaults = .standard) {
        if defaults.string(forKey: lastSeenKey) == nil { recordSeen(defaults: defaults) }
    }
    static func recordSeen(defaults: UserDefaults = .standard) {
        defaults.set(marketingVersion, forKey: lastSeenKey)
    }
}

private extension ChangeKind {
    var tint: Color {
        switch self {
        case .new: return AsteriaTheme.accent
        case .improved: return Color(red: 0.29, green: 0.70, blue: 1.0)
        case .fixed: return Color(red: 0.33, green: 0.81, blue: 0.56)
        case .removed: return Color(red: 0.60, green: 0.64, blue: 0.70)
        case .known: return Color(red: 0.90, green: 0.66, blue: 0.29)
        case .experimental: return Color(red: 0.73, green: 0.55, blue: 1.0)
        }
    }
}

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ChangeItem] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(ChangeKind.allCases, id: \.self) { kind in
                        group(kind, rows: items.filter { $0.kind == kind })
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 8)
            }
            footer
        }
        .frame(width: 480, height: 620)
        .background(AsteriaTheme.background)
        .task { items = await WhatsNew.currentChangelog()?.orderedItems() ?? [] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("What's New", systemImage: "sparkles")
                .font(.system(size: 11, weight: .semibold)).textCase(.uppercase)
                .foregroundStyle(AsteriaTheme.accent)
                .labelStyle(.titleAndIcon)
            Text("Version \(WhatsNew.marketingVersion)")
                .font(.system(size: 26, weight: .bold)).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 26).padding(.bottom, 4)
    }

    @ViewBuilder private func group(_ kind: ChangeKind, rows: [ChangeItem]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(kind.displayLabel.uppercased())
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(kind.tint)
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
                .padding(.top, 20).padding(.bottom, 10)
                ForEach(rows, id: \.title) { row($0) }
            }
        }
    }

    private func row(_ item: ChangeItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 17)).foregroundStyle(item.kind.tint)
                .frame(width: 26, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 14, weight: .semibold))
                if item.text != item.title {
                    Text(markdown(item.text)).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }

    /// Renders inline markdown (e.g. `*italic*`) from the runtime string; plain text is a safe fallback.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Continue") { dismiss() }
                .buttonStyle(.borderedProminent).tint(AsteriaTheme.accent)
                .controlSize(.large)
        }
        .padding(.horizontal, 30).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }
}
