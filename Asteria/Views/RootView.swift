import SwiftUI
import AppKit
import CoreImage
import UserNotifications
import AsteriaKit

/// Host-picker shell; shows onboarding on first launch or when ASTERIA_FIRST_TIME_SETUP is set.
struct RootView: View {
    @State private var store: HostListStore
    @State private var selectedHost: HostRecord?
    @State private var settingsScope: SettingsEditor.Scope?
    @State private var streamRequest: StreamRequest?
    @State private var pendingStreamTitle: String?
    /// Bumped each time a stream ends, so the library refreshes once to pick up the host's running state.
    @State private var libraryRefreshToken = 0
    @State private var didLoad = false
    @State private var showOnboarding = false
    @State private var showWhatsNew = false

    /// Dev override: launch straight into onboarding even if it was completed previously.
    private let forceFirstRun = ProcessInfo.processInfo.environment["ASTERIA_FIRST_TIME_SETUP"] != nil

    init() {
        let repository: any LibraryRepository =
            (try? JSONFileLibraryRepository()) ?? InMemoryLibraryRepository()
        _store = State(initialValue: HostListStore(repository: repository))
    }

    #if DEBUG
    init(previewStore: HostListStore) {
        _store = State(initialValue: previewStore)
    }
    #endif

    var body: some View {
        ZStack {
            if !didLoad {
                AsteriaTheme.background.ignoresSafeArea()
            } else if showOnboarding {
                OnboardingView(store: store) {
                    Task {
                        await store.completeOnboarding()   // persist before navigating, so a skip can't lose the race
                        withAnimation { showOnboarding = false }
                    }
                }
                .transition(.opacity)
            } else {
                ZStack {
                    shell
                    if let pendingStreamTitle {
                        pendingStreamOverlay(title: pendingStreamTitle)
                            .transition(.opacity)
                    }
                    if let request = streamRequest {
                        StreamContainerView(host: request.host, entry: request.entry, library: store,
                                            notificationsAllowed: request.notificationsAllowed) {
                            streamRequest = nil
                            libraryRefreshToken += 1
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .sheet(isPresented: $showWhatsNew, onDismiss: { WhatsNew.recordSeen() }) { WhatsNewSheet() }
        .alert("Couldn't load saved PCs", isPresented: loadErrorBinding) {
            Button("OK") { store.dismissLoadError() }
        } message: {
            Text(store.loadError ?? "The saved PC library could not be loaded.")
        }
        .task {
            guard !didLoad else { return }
            if isRunningInPreview { didLoad = true; return }
            await store.load()
            showOnboarding = forceFirstRun || !store.isOnboardingComplete
            var presentWhatsNew = false
            if !showOnboarding { presentWhatsNew = await WhatsNew.shouldPresent() }
            if WhatsNew.forceShowOverride { presentWhatsNew = true }
            if presentWhatsNew {
                showWhatsNew = true
            } else {
                WhatsNew.recordSeenIfNeeded()
            }
            didLoad = true
        }
    }

    private var loadErrorBinding: Binding<Bool> {
        Binding(
            get: { store.loadError != nil },
            set: { if !$0 { store.dismissLoadError() } })
    }

    @ViewBuilder private var shell: some View {
        if let scope = settingsScope {
            SettingsView(scope: scope, library: store,
                         onClose: { settingsScope = nil })
        } else if let host = selectedHost {
            HostDetailView(host: host, store: store,
                           refreshToken: libraryRefreshToken,
                           callbacks: HostDetailCallbacks(
                                onBack: { selectedHost = nil },
                                onUpdate: { selectedHost = $0 },
                                onOpenSettings: { settingsScope = .host(host) },
                                onStream: { beginStream(host: $0, entry: $1) }
                            ))
        } else {
            HostPickerView(store: store,
                           onOpenSettings: { settingsScope = .global }) { host in
                selectedHost = host
            }
        }
    }

    private func beginStream(host: HostRecord, entry: AppLibraryEntry) {
        guard pendingStreamTitle == nil, streamRequest == nil else { return }
        pendingStreamTitle = entry.title
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let allowed: Bool
            switch settings.authorizationStatus {
            case .notDetermined:
                allowed = (try? await center.requestAuthorization(options: [.alert])) == true
            case .authorized, .provisional, .ephemeral:
                allowed = true
            case .denied:
                allowed = false
            @unknown default:
                allowed = false
            }
            pendingStreamTitle = nil
            streamRequest = StreamRequest(host: host, entry: entry,
                                          notificationsAllowed: allowed)
        }
    }

    private func pendingStreamOverlay(title: String) -> some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Preparing \(title)…").font(.title2.weight(.semibold))
                Text("Waiting for notification permission")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }
}

/// A pending request to stream one app on one host, surfaced by a library card tap.
struct StreamRequest: Identifiable, Equatable {
    let host: HostRecord
    let entry: AppLibraryEntry
    let notificationsAllowed: Bool
    var id: String { "\(host.id)-\(entry.appId)" }
}

/// Callbacks for the selected-host detail flow.
struct HostDetailCallbacks {
    let onBack: () -> Void
    let onUpdate: (HostRecord) -> Void
    let onOpenSettings: () -> Void
    let onStream: (HostRecord, AppLibraryEntry) -> Void
}

/// A selected host: pairs it if needed, otherwise shows the (placeholder) library entry.
struct HostDetailView: View {
    let host: HostRecord
    let store: HostListStore
    var appName = "Asteria"
    var refreshToken: Int = 0
    let callbacks: HostDetailCallbacks

    @State private var coordinator: PairingCoordinator?

    var body: some View {
        Group {
            if let coordinator {
                PairingView(coordinator: coordinator) { handleClose() }
            } else if host.isPaired {
                PairedHostView(host: host, refreshToken: refreshToken,
                               onOpenSettings: callbacks.onOpenSettings,
                               onBack: callbacks.onBack,
                               onPairAgain: beginPairing,
                               onLaunch: { callbacks.onStream(host, $0) })
            } else {
                detailScaffold(title: host.displayName, subtitle: host.address,
                               hints: [ControllerHint(glyph: .b, label: "Back")]) {
                    ProgressView()
                }
            }
        }
        .task {
            if !host.isPaired && coordinator == nil { beginPairing() }
        }
    }

    /// Cancelling or finishing an initial pairing returns to the picker if the host is still unpaired.
    private func handleClose() {
        coordinator = nil
        if !host.isPaired { callbacks.onBack() }
    }

    private func detailScaffold<Body: View>(title: String, subtitle: String, hints: [ControllerHint],
                                            @ViewBuilder content: () -> Body) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    callbacks.onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                    .buttonStyle(.plain)
                Spacer()
            }
            .padding(20)
            Spacer()
            VStack(spacing: 10) {
                Text(title).font(.largeTitle.bold())
                Text(subtitle).foregroundStyle(.secondary)
                content().padding(.top, 12)
            }
            Spacer()
            ControllerHintBar(hints: hints)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AsteriaTheme.background)
        .foregroundStyle(.white)
    }

    private func beginPairing() {
        coordinator = PairingCoordinator(host: host, deviceName: appName) { updated in
            callbacks.onUpdate(updated)
            await store.markPaired(updated)
        }
    }
}

/// Owns the app-library store for one paired host and launches the live stream from a card tap.
struct PairedHostView: View {
    @State private var store: AppLibraryStore
    var refreshToken: Int
    var onOpenSettings: () -> Void
    var onBack: () -> Void
    var onPairAgain: () -> Void
    var onLaunch: (AppLibraryEntry) -> Void

    init(host: HostRecord, refreshToken: Int = 0,
         onOpenSettings: @escaping () -> Void = {}, onBack: @escaping () -> Void,
         onPairAgain: @escaping () -> Void = {},
         onLaunch: @escaping (AppLibraryEntry) -> Void = { _ in }) {
        _store = State(initialValue: AppLibraryStore(host: host))
        self.refreshToken = refreshToken
        self.onOpenSettings = onOpenSettings
        self.onBack = onBack
        self.onPairAgain = onPairAgain
        self.onLaunch = onLaunch
    }

    #if DEBUG
    init(previewStore: AppLibraryStore, refreshToken: Int = 0,
         onOpenSettings: @escaping () -> Void = {}, onBack: @escaping () -> Void = {},
         onPairAgain: @escaping () -> Void = {},
         onLaunch: @escaping (AppLibraryEntry) -> Void = { _ in }) {
        _store = State(initialValue: previewStore)
        self.refreshToken = refreshToken
        self.onOpenSettings = onOpenSettings
        self.onBack = onBack
        self.onPairAgain = onPairAgain
        self.onLaunch = onLaunch
    }
    #endif

    var body: some View {
        AppLibraryView(store: store, onLaunch: onLaunch,
                       onOpenSettings: onOpenSettings, onBack: onBack,
                       onPairAgain: onPairAgain,
                       refreshToken: refreshToken)
    }
}

/// First-run flow: Welcome → Sunshine install → pair → connection test → done.
struct OnboardingView: View {
    let store: HostListStore
    var onFinish: () -> Void

    private enum Step: String { case welcome, sunshine, pair, test, done }
    @State private var step: Step = .welcome

    @State private var target: HostRecord?
    @State private var showManual = false
    @State private var manualText = ""
    @State private var coordinator: PairingCoordinator?
    @State private var pin = ""

    @State private var recommended: StreamSettings?
    @State private var reco: RecoSummary?
    @State private var capabilities: StreamCapabilities = .unrestricted
    @State private var availableCodecs: [CodecPreference] = []
    @State private var guideHover = false
    @State private var adjustOpen = false
    @State private var openAdjustMenu: String?
    @State private var adjResolution: VideoResolution = .matchDisplay
    @State private var adjFrameRate: FrameRate = .matchDisplay
    @State private var adjCodec: CodecPreference = .auto
    @State private var adjBitrateKbps = 20000
    @State private var showQR = false

    private let guideURL = "https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html"
    /// Dev override: skip Sunshine setup when a paired host already exists.
    private let skipPairingOverride =
        ProcessInfo.processInfo.environment["ASTERIA_ONBOARDING_SKIP_PAIRING"]?.lowercased() == "true"

    var body: some View {
        ZStack {
            AsteriaTheme.background.ignoresSafeArea()
            switch step {
            case .welcome: welcomeStep
            case .sunshine: scaffold(pill: "On your PC", index: 1) { sunshineStep }
            case .pair: scaffold(pill: "PC found", pillOK: true, index: 2) { pairStep }
            case .test: scaffold(pill: "Quality", index: 3) { testStep }
            case .done: doneStep
            }
            if showQR { qrOverlay }
        }
        .foregroundStyle(.white)
        .task(id: step.rawValue) { await runStep() }
    }

    private var qrOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea().onTapGesture { showQR = false }
            VStack(spacing: 14) {
                if let qr = qrImage(from: guideURL) {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: 280, height: 280)
                        .padding(16).background(.white, in: .rect(cornerRadius: 18))
                }
                Text("Scan with your phone for the Sunshine setup guide").font(.callout)
                Text("Click anywhere to close").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func advance(to next: Step) { withAnimation(.easeInOut(duration: 0.3)) { step = next } }

    private func runStep() async {
        guard !isRunningInPreview else { return }
        switch step {
        case .sunshine: await runDiscovery()
        case .pair: await runPairing()
        case .test: await runTest()
        default: break
        }
    }

    private func runDiscovery() async {
        showManual = false
        let start = Date()
        while !Task.isCancelled {
            await store.refresh()
            if let found = store.hosts.first(where: { store.availability(for: $0) == .online })
                ?? store.hosts.first(where: { store.availability(for: $0) != .offline }) {
                target = found       // enable Continue; never auto-advance. The user chooses to proceed
                return
            }
            if Date().timeIntervalSince(start) > 15 { showManual = true }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func addManual() {
        let text = manualText
        guard ManualHostAddress.normalize(text) != nil else { return }
        Task {
            await store.addManualHost(text)
            target = store.hosts.last
        }
    }

    private func runPairing() async {
        guard let target else { return }
        pin = ""
        let coord = PairingCoordinator(
            host: target, deviceName: "Asteria"
        ) { updated in
            await store.markPaired(updated)
        }
        coordinator = coord
        await coord.start()       // leaves phase at .paired; the user clicks Continue to advance
    }

    private func retryPairing() { Task { await coordinator?.start() } }

    private func runTest() async {
        reco = nil
        try? await Task.sleep(for: .seconds(0.4))   // brief beat so the recommendation doesn't pop in abruptly
        if Task.isCancelled { return }
        capabilities = SettingsEditor.detectCapabilities()
        let rec = buildRecommendation()
        recommended = rec.settings
        reco = rec.summary
        availableCodecs = rec.codecs
        adjResolution = rec.settings.resolution
        adjFrameRate = rec.settings.frameRate
        adjCodec = rec.settings.codec
        adjBitrateKbps = rec.summary.mbps * 1000
    }

    private struct Recommendation { var settings: StreamSettings; var summary: RecoSummary; var codecs: [CodecPreference] }

    private func buildRecommendation() -> Recommendation {
        let caps = capabilities
        let settings = StreamPlan.firstRunRecommendation(global: store.globalSettings,
                                                         capabilities: caps)
        let resolutionText: String
        if let display = caps.displaySize {
            resolutionText = "\(display.width)×\(display.height)"
        } else {
            resolutionText = "1920×1080"
        }
        let kbps = settings.bitrate.resolvedKbps(
            recommendedKbps: StreamPlan.recommendedKbps(for: settings, capabilities: caps))
        let summary = RecoSummary(resolution: resolutionText, fps: 60,
                                  mbps: max(1, kbps / 1000),
                                  codec: Self.codecLabel(settings.codec, tenBit: false))
        return Recommendation(settings: settings, summary: summary, codecs: caps.codecs)
    }

    private func applyRecommendation() {
        guard var settings = recommended else { advance(to: .done); return }
        settings.resolution = adjResolution
        settings.frameRate = adjFrameRate
        settings.codec = adjCodec
        settings.bitrate = .manual(kbps: max(500, adjBitrateKbps))
        // Clamp like every other commit path — unsupported picks downgrade.
        let plan = StreamPlan.resolve(settings: settings, capabilities: capabilities)
        Task { await store.updateGlobalSettings(plan.settings) }
        advance(to: .done)
    }

    private var welcomeStep: some View {
        ZStack {
            StarfieldBackground().ignoresSafeArea()
            welcomeContent
        }
    }

    private var welcomeContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Stream your PC to this Mac.")
                .font(.system(size: 34, weight: .bold)).multilineTextAlignment(.center)
            Text("Low-latency game streaming from your Windows PC, with controller, keyboard & mouse support.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520)
            primaryButton("Get started", big: true) {
                advance(to: shouldSkipPairing ? .test : .sunshine)
            }.padding(.top, 18)
            Button("Skip setup") { onFinish() }
                .buttonStyle(.plain).font(.caption2).foregroundStyle(.tertiary).hoverHand()
                .padding(.top, 10)
            Text("Setup process takes ~10 minutes, you'll need a PC connected to your local home network.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520).padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sunshineStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("Install Sunshine on your PC").font(.system(size: 26, weight: .semibold))
            Text("Sunshine is a free, open-source game-stream host that Asteria connects to. " +
                  "Install it on the PC you want to stream from, then launch it.")
                .font(.system(size: 14)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    label("1", "Open the Sunshine guide (or scan the QR code).")
                    label("2", "Download, install, and launch Sunshine.")
                    label("3", "Keep that PC on this same network.")
                    Link(destination: URL(string: guideURL)!) {
                        Text("Open setup guide ↗").font(.callout.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(guideHover ? AsteriaTheme.surfaceFocused : AsteriaTheme.surface, in: .capsule)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(guideHover ? 0.3 : 0.14)))
                    }
                    .buttonStyle(.plain).tint(.white).padding(.top, 4)
                    .onHover { h in guideHover = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                        Text(apolloNotice).hoverHand()
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let qr = qrImage(from: guideURL) {
                    VStack(spacing: 7) {
                        Button { showQR = true } label: {
                            Image(nsImage: qr).interpolation(.none).resizable()
                                .frame(width: 128, height: 128)
                                .padding(8).background(.white, in: .rect(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        Text("Click to enlarge").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 22)
            discoveryStatus.padding(.top, 20)
            Spacer()
            footer {
                primaryButton(target == nil ? "Continue" : "Continue →") {
                    if target != nil { advance(to: .pair) }
                }
                .disabled(target == nil).opacity(target == nil ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var discoveryStatus: some View {
        if let target {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Found \(target.displayName)").font(.callout.weight(.semibold))
                    Text(target.address).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.green.opacity(0.10), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(0.35)))
        } else if showManual {
            VStack(alignment: .leading, spacing: 10) {
                Text("Don't see your PC yet?").font(.subheadline.weight(.semibold))
                Text("Make sure Sunshine is running on it. You can also enter its address directly:")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("192.168.1.XXX or hostname", text: $manualText)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    Button("Add") { addManual() }
                        .disabled(ManualHostAddress.normalize(manualText) == nil)
                }
                DisclosureGroup("Not seeing it?") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("• Make sure the PC and this Mac are on the same Wi-Fi / network.")
                        Text("• Make sure the PC's firewall isn't blocking Sunshine.")
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                .font(.caption).tint(.white)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AsteriaTheme.surface, in: .rect(cornerRadius: 10))
        } else {
            statusRow(color: AsteriaTheme.accent, systemImage: "antenna.radiowaves.left.and.right",
                      text: "Scanning your network for your PC…", showSpinner: true)
        }
    }

    private var pairStep: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("Pair with \(target?.displayName ?? "your PC")").font(.system(size: 22, weight: .semibold))
                .padding(.bottom, 24)
            dial
            HStack(spacing: 6) {
                Text("Enter this code in Sunshine at")
                Text("\(target?.address ?? "localhost"):47990").font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(AsteriaTheme.surface, in: .rect(cornerRadius: 6))
                Text("→ PIN tab")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.top, 24)
            pairStatus.padding(.top, 18)
            Spacer()
            footer {
                primaryButton("Continue →") { advance(to: .test) }
                    .disabled(!isPaired).opacity(isPaired ? 1 : 0.4)
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: phaseKey) { _, _ in
            if case let .awaitingPIN(p, _)? = coordinator?.phase { pin = p }
        }
    }

    private var dial: some View {
        let phase = coordinator?.phase ?? .preparing
        let paired = isPaired
        let failed = { if case .failed = phase { return true }; return false }()
        let verifying = { if case .verifying = phase { return true }; return false }()
        let active = !paired && !failed
        let arcColor: Color = paired ? .green : (failed ? Color.white.opacity(0.12) : AsteriaTheme.accent)
        let labelText = failed ? "Code expired" : (paired ? "Paired" : "Pairing PIN")
        let value = pin.isEmpty ? "••••" : pin
        return ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 4)
            if active {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(arcColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 3) / 3 * 360))
                }
            } else {
                Circle().stroke(arcColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            VStack(spacing: 7) {
                HStack(spacing: 5) {
                    if active { Image(systemName: "lock").font(.system(size: 9, weight: .semibold)) }
                    Text(labelText.uppercased()).tracking(1.5)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(failed ? Color.red.opacity(0.85) : (paired ? .green : .secondary))
                Text(value).font(.system(size: 40, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white).opacity(verifying ? 0.5 : 1)
            }
        }
        .frame(width: 220, height: 220)
    }

    @ViewBuilder private var pairStatus: some View {
        switch coordinator?.phase {
        case .verifying:
            statusRow(color: AsteriaTheme.accent, systemImage: nil,
                      text: "Verifying with \(target?.displayName ?? "your PC")…", showSpinner: true)
        case .paired:
            statusRow(color: .green, systemImage: "checkmark.circle.fill", text: "Paired")
        case .failed(let message):
            VStack(spacing: 12) {
                statusRow(color: .red, systemImage: "xmark.circle.fill", text: message)
                primaryButton("Get a new PIN") { retryPairing() }
            }
        default:
            statusRow(color: .secondary, systemImage: nil, text: "Waiting for you to enter this PIN…",
                      showSpinner: true)
        }
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("Tuned for your setup").font(.system(size: 26, weight: .semibold))
            Text("We've set balanced defaults for a smooth, stable stream to start. You can push the quality higher anytime in Settings.")
                .font(.system(size: 14)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            if let reco {
                Text("RECOMMENDED SETTINGS").font(.caption2.weight(.semibold)).tracking(0.5)
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 24)
                HStack(spacing: 10) {
                    recoChip("Resolution", "\(reco.resolution) · \(reco.fps)")
                    recoChip("Bitrate", "\(reco.mbps) Mbps")
                    recoChip("Codec", reco.codec)
                }
                .padding(.top, 10).frame(maxWidth: .infinity)
                adjustControls
            } else {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Preparing…").foregroundStyle(.secondary) }
                    .padding(.top, 24)
            }
            Spacer()
            footer {
                HStack(spacing: 10) {
                    Button("Keep defaults") { advance(to: .done) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    primaryButton("Apply") { applyRecommendation() }.disabled(reco == nil).opacity(reco == nil ? 0.4 : 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var adjustControls: some View {
        DisclosureGroup("Adjust", isExpanded: $adjustOpen) {
            VStack(spacing: 0) {
                adjustRow("Resolution") {
                    DeckMenu(resolutionText(adjResolution), items: resolutionItems, isOpen: menuBinding("resolution"))
                }
                adjustRow("Frame rate") {
                    DeckMenu(frameRateText(adjFrameRate), items: frameRateItems, isOpen: menuBinding("framerate"))
                }
                adjustRow("Bitrate") {
                    DeckMenu("\(max(1, adjBitrateKbps / 1000)) Mbps", items: bitrateItems,
                             isOpen: menuBinding("bitrate"))
                }
                adjustRow("Codec") {
                    DeckMenu(Self.codecLabel(adjCodec, tenBit: false), items: codecItems, isOpen: menuBinding("codec"))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(AsteriaTheme.surface, in: .rect(cornerRadius: AsteriaTheme.cardCorner))
            .overlay(RoundedRectangle(cornerRadius: AsteriaTheme.cardCorner).strokeBorder(.white.opacity(0.08)))
            .padding(.top, 10)
        }
        .tint(.white).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
    }

    private func adjustRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 15, weight: .medium))
            Spacer(minLength: 16)
            control()
        }
        .padding(.horizontal, 6).frame(minHeight: 54)
    }

    private func menuBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { openAdjustMenu == key }, set: { openAdjustMenu = $0 ? key : nil })
    }

    private func resolutionText(_ r: VideoResolution) -> String {
        switch r {
        case .matchDisplay: return "Match display"
        case let .preset(w, h), let .custom(w, h): return "\(w)×\(h)"
        }
    }

    private func frameRateText(_ f: FrameRate) -> String {
        switch f {
        case .matchDisplay: return "Match display"
        case let .fps(v): return "\(v)"
        }
    }

    private var resolutionItems: [DeckMenuItem] {
        [(.hd720, "1280×720"), (.matchDisplay, "Match display"), (.hd1080, "1920×1080"),
         (.qhd1440, "2560×1440"), (.uhd4K, "3840×2160")]
            .map { res, name in
                DeckMenuItem(name, selected: adjResolution == res) {
                    adjResolution = res
                }
            }
    }

    private var frameRateItems: [DeckMenuItem] {
        [(.fps30, "30"), (.matchDisplay, "Match display"), (.fps60, "60"),
         (.fps120, "120"), (.fps240, "240")]
            .map { rate, name in
                DeckMenuItem(name, selected: adjFrameRate == rate) {
                    adjFrameRate = rate
                }
            }
    }

    private var bitrateItems: [DeckMenuItem] {
        [10, 20, 30, 50, 80, 100].map { mbps in
            DeckMenuItem("\(mbps) Mbps", selected: adjBitrateKbps == mbps * 1000) {
                adjBitrateKbps = mbps * 1000
            }
        }
    }

    private var codecItems: [DeckMenuItem] {
        [DeckMenuItem("Auto", selected: adjCodec == .auto) { adjCodec = .auto }]
            + availableCodecs.map { codec in
                DeckMenuItem(Self.codecLabel(codec, tenBit: false), selected: adjCodec == codec) { adjCodec = codec }
            }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(.green)
            Text("You're all set.").font(.system(size: 30, weight: .bold))
            Text("\(target?.displayName ?? "Your PC") is now setup and ready to go.")
                .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            primaryButton("Let's play", big: true) { onFinish() }.padding(.top, 18)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var shouldSkipPairing: Bool {
        skipPairingOverride && store.hosts.contains(where: \.isPaired)
    }

    private func scaffold<Content: View>(pill: String, pillOK: Bool = false, index: Int,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(pill.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5)
                    .foregroundStyle(pillOK ? Color.green : AsteriaTheme.accent)
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background((pillOK ? Color.green : AsteriaTheme.accent).opacity(0.12), in: .capsule)
                Spacer()
                HStack(spacing: 10) {
                    Text("Step \(index) of 3").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(1...3, id: \.self) { i in
                            Circle().fill(i == index ? AsteriaTheme.accent
                                          : (i < index ? Color.secondary : Color.white.opacity(0.12)))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .padding(.horizontal, 44).padding(.top, 34)
            content().padding(.horizontal, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            Button { backFromStep() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            content()
        }
        .padding(.top, 18).padding(.bottom, 24)
    }

    private func backFromStep() {
        switch step {
        case .sunshine: advance(to: .welcome)
        case .pair: advance(to: .sunshine)
        case .test: advance(to: shouldSkipPairing ? .welcome : .pair)
        default: break
        }
    }

    private func primaryButton(_ title: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout.weight(.semibold))
                .padding(.horizontal, big ? 26 : 18).padding(.vertical, big ? 11 : 9)
        }
        .buttonStyle(.plain).background(AsteriaTheme.accent, in: .capsule)
    }

    private func label(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.monospaced()).foregroundStyle(AsteriaTheme.accent)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func recoChip(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13).background(AsteriaTheme.surface, in: .rect(cornerRadius: 10))
    }

    private func statusRow(color: Color, systemImage: String?, text: String, showSpinner: Bool = false) -> some View {
        HStack(spacing: 9) {
            if showSpinner { ProgressView().controlSize(.small) }
            else if let systemImage { Image(systemName: systemImage).foregroundStyle(color) }
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var isPaired: Bool { if case .paired = coordinator?.phase { return true }; return false }

    private var phaseKey: String {
        switch coordinator?.phase {
        case .preparing: return "preparing"
        case .awaitingPIN(let p, _): return "pin:\(p)"
        case .verifying: return "verifying"
        case .paired: return "paired"
        case .failed(let m): return "failed:\(m)"
        case nil: return "nil"
        }
    }

    private var apolloNotice: AttributedString {
        var text = AttributedString("Try out ")
        var vibepollo = AttributedString("Vibepollo")
        vibepollo.link = URL(string: "https://github.com/Nonary/Vibepollo")
        vibepollo.foregroundColor = AsteriaTheme.accent
        vibepollo.underlineStyle = .single
        text += vibepollo
        text += AttributedString(", a fork of Apollo that integrates all of the scripts from Nonary " +
            "and has an extensive feature-set.")
        return text
    }

    private func qrImage(from string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func codecLabel(_ codec: CodecPreference, tenBit: Bool) -> String {
        switch codec {
        case .av1: return tenBit ? "AV1 10-bit" : "AV1"
        case .hevc: return tenBit ? "HEVC 10-bit" : "HEVC"
        case .h264: return "H.264"
        case .auto: return "Auto"
        }
    }
}

/// The applied recommendation, formatted for the connection-test summary chips.
struct RecoSummary {
    var resolution: String
    var fps: Int
    var mbps: Int
    var codec: String
}

/// Shows the macOS pointing-hand cursor on hover so links/buttons read as clickable.
private struct HoverHand: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension View {
    fileprivate func hoverHand() -> some View { modifier(HoverHand()) }
}

#if DEBUG
#Preview("Onboarding") {
    OnboardingView(store: .preview(hosts: [])) {}
        .frame(width: 900, height: 640)
}

#Preview("Root: picker") {
    RootView(previewStore: .preview(hosts: HostPickerPreviewData.hosts,
                                    availability: HostPickerPreviewData.availability))
}

#Preview("Host detail: paired library") {
    PairedHostView(previewStore: .preview(host: AppLibraryPreviewData.host,
                                          entries: AppLibraryPreviewData.entries,
                                          art: AppLibraryPreviewData.art))
    .frame(width: 900, height: 640)
}
#endif
