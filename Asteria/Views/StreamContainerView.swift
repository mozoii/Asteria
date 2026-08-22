import SwiftUI
import AsteriaKit

/// Shared glass tint so in-stream surfaces read the same over video.
private let streamGlassTint = Color.black.opacity(0.5)

/// A menu item's key equivalent, saved so it can be restored after immersive full screen suppresses it.
private struct SavedShortcut {
    let item: NSMenuItem
    let key: String
    let mods: NSEvent.ModifierFlags
}

private final class StreamContainerPresence {
    var generation = 0
}

/// Full-bleed live stream: connects on appear, presents the video layer, and routes hotkeys + full screen.
struct StreamContainerView: View {
    @State private var controller: StreamController
    @State private var window: NSWindow?
    @State private var didEnterFullscreen = false
    @State private var fullscreenFrame: NSRect = .zero
    @State private var libraryFrame: NSRect?
    @State private var savedLevel: NSWindow.Level = .normal
    @State private var savedShadow = true
    @State private var savedPresentation: NSApplication.PresentationOptions = []
    @State private var clearedShortcuts: [SavedShortcut] = []
    @State private var didResizeForWindowedMode = false
    @State private var presence = StreamContainerPresence()
    private let keybindings: Keybindings
    var onClose: () -> Void

    init(host: HostRecord, entry: AppLibraryEntry, library: HostListStore,
         notificationsAllowed: Bool = true,
         onClose: @escaping () -> Void) {
        let capabilities = SettingsEditor.detectCapabilities()
        let plan = StreamPlan.resolve(global: library.globalSettings,
                                      override: library.override(for: host),
                                      capabilities: capabilities)
        let prefs = library.inputPreferences
        _controller = State(initialValue: StreamController(
            host: host, entry: entry, settings: plan.settings,
            capabilities: capabilities, inputPreferences: prefs,
            overlayPreferences: library.overlayPreferences,
            notificationsAllowed: notificationsAllowed))
        self.keybindings = prefs.keybindings
        self.onClose = onClose
    }

    #if DEBUG
    init(previewController: StreamController, keybindings: Keybindings = .defaults,
         onClose: @escaping () -> Void = {}) {
        _controller = State(initialValue: previewController)
        self.keybindings = keybindings
        self.onClose = onClose
    }
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .background(WindowAccessor { newWindow in
            window = newWindow
            if let newWindow, controller.phase == .streaming {
                scheduleWindowedTitleBarSetting(for: newWindow)
            }
            // Window can resolve after .streaming on a reconnect, so re-attempt here or the entry is lost.
            if let newWindow { enterFullscreenIfStreaming(newWindow) }
        })
        .task { if !isRunningInPreview { await controller.connect() } }
        .onChange(of: controller.phase) { _, phase in
            if phase == .streaming, let window {
                scheduleWindowedTitleBarSetting(for: window)
                enterFullscreenIfStreaming(window)
            }
            if phase == .ended { exitFullscreenIfNeeded(); onClose() }
        }
        .onAppear {
            presence.generation += 1
            controller.onToggleFullscreen = toggleFullscreen
        }
        .onDisappear {
            let closingWindow = window
            scheduleTeardownIfStillAbsent(window: closingWindow, frame: libraryFrame,
                                          generation: presence.generation)
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .connecting:
            statusScreen(spinner: true, title: "Launching \(controller.title)…", detail: nil) { EmptyView() }
        case .failed(let message):
            statusScreen(spinner: false, title: "Couldn't start the stream", detail: message) {
                Button("Try again") { controller.reconnect() }.buttonStyle(.borderedProminent)
                Button("Back") { onClose() }
            }
        case .connectionLost:
            statusScreen(spinner: false, title: "Connection lost",
                         detail: "The stream to \(controller.title) dropped. Reconnecting will restart the game on the host.") {
                Button("Reconnect") { controller.reconnect() }.buttonStyle(.borderedProminent)
                Button("Back to library") { exitAndClose() }
            }
        case .streaming, .ended:
            if let layer = controller.videoLayer {
                StreamView(layer: layer, capture: controller.inputCapture)
                    .ignoresSafeArea()
                    .overlay {
                        if !controller.showMenu {
                            StreamControlsOverlay(capture: controller.inputCapture, prompt: recapturePrompt)
                        }
                    }
                    .overlay(alignment: .topTrailing) { if controller.showStats { statsHUD } }
                    .overlay(alignment: .topLeading) {
                        if let toast = controller.currentToast { StreamToastView(toast: toast) }
                    }
                    .overlay { if controller.showMenu { StreamOverlayMenu(controller: controller) } }
                    .overlay { if controller.resumeStalled { resumeStalledPrompt } }
                    .animation(.easeInOut(duration: 0.15), value: controller.showMenu)
            } else {
                statusScreen(spinner: true, title: "Starting…", detail: nil) { EmptyView() }
            }
        }
    }

    /// Shown when a resumed session never delivered video: offer quit+relaunch or keep waiting.
    private var resumeStalledPrompt: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            statusScreen(spinner: false, title: "Resume didn't start video",
                         detail: "Reconnected to \(controller.title), but the host isn't sending video. Quitting and relaunching restarts the game.") {
                Button("Quit & relaunch") { controller.relaunchAfterStalledResume() }
                    .buttonStyle(.borderedProminent)
                Button("Keep waiting") { controller.dismissStalledResume() }
            }
        }
    }

    private var statsHUD: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(controller.statsModel.lines) { line in
                HStack(spacing: 8) {
                    Text(line.label).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(line.value).foregroundStyle(color(for: line.emphasis)).lineLimit(1)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .frame(width: 190)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .glassEffect(.regular.tint(streamGlassTint), in: .rect(cornerRadius: 12))
        .padding(16)
    }

    private func color(for emphasis: StatEmphasis) -> Color {
        switch emphasis {
        case .normal: return .white
        case .warn: return .orange
        case .good: return .green
        case .lowBattery: return .yellow
        case .criticalBattery: return .red
        }
    }

    private func statusScreen<Actions: View>(spinner: Bool, title: String, detail: String?,
                                             @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 16) {
            if spinner { ProgressView().controlSize(.large) }
            Text(title).font(.title2.weight(.semibold))
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            HStack(spacing: 12) { actions() }.padding(.top, 4)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bottom prompt shown while input is released (not via the menu): how to recapture and reach the menu.
    private var recapturePrompt: String {
        var parts = ["Click to capture input"]
        if let menu = keybindings.keyboard[.toggleOverlayMenu], !menu.isEmpty {
            parts.append("\(menu.displayString) for menu")
        }
        return parts.joined(separator: " · ")
    }

    private func toggleFullscreen() {
        guard let window else { return }
        if didEnterFullscreen { exitImmersiveFullscreen(window) } else { enterImmersiveFullscreen(window) }
    }

    /// Enter full screen once streaming and the window both exist; idempotent so it can't double-enter.
    private func enterFullscreenIfStreaming(_ window: NSWindow) {
        guard controller.startFullscreen, controller.phase == .streaming, !didEnterFullscreen else { return }
        enterImmersiveFullscreen(window)
    }

    private func exitFullscreenIfNeeded() {
        guard didEnterFullscreen, let window else { return }
        exitImmersiveFullscreen(window)
    }

    /// Immersive full screen: no Space transition (it severs GCMouse/GCKeyboard HID routing); drops only `.titled`
    /// (a title-less window can't be key, suppressing ⌘-Q/W/M/H which GCKeyboard relays to the host); re-inserted on exit.
    private func enterImmersiveFullscreen(_ window: NSWindow) {
        guard !didEnterFullscreen, let screen = window.screen ?? NSScreen.main else { return }
        fullscreenFrame = window.frame
        savedLevel = window.level
        savedShadow = window.hasShadow
        savedPresentation = NSApp.presentationOptions
        suppressMenuShortcuts()
        setTitleBarVisible(false, on: window)
        window.hasShadow = false   // the frame shadow rims the screen-covering window as a thin white outline
        NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)   // cover the menu bar
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        didEnterFullscreen = true
    }

    private func exitImmersiveFullscreen(_ window: NSWindow) {
        guard didEnterFullscreen else { return }
        NSApp.presentationOptions = savedPresentation
        applyConfiguredWindowedTitleBar(to: window)
        window.hasShadow = savedShadow
        window.level = savedLevel
        window.setFrame(fullscreenFrame, display: true)
        restoreMenuShortcuts()
        didEnterFullscreen = false
    }

    private func applyWindowedTitleBarSetting(to window: NSWindow) {
        guard !didEnterFullscreen else { return }
        applyConfiguredWindowedTitleBar(to: window)
        resizeForWindowedStreamIfNeeded(window)
    }

    /// SwiftUI resolves windows and publishes phase changes while AppKit may be enumerating its view tree.
    /// Defer frame-view rebuilding until that traversal finishes.
    private func scheduleWindowedTitleBarSetting(for window: NSWindow) {
        DispatchQueue.main.async {
            guard self.window === window, controller.phase == .streaming else { return }
            applyWindowedTitleBarSetting(to: window)
        }
    }

    private func applyConfiguredWindowedTitleBar(to window: NSWindow) {
        setTitleBarVisible(!controller.hideTitleBarInWindowedMode, on: window)
    }

    private func scheduleWindowRestoration(for window: NSWindow, frame: NSRect?) {
        DispatchQueue.main.async {
            setTitleBarVisible(true, on: window)
            if let frame { window.setFrame(frame, display: true) }
        }
    }

    /// AppKit frame-view rebuilds can transiently detach and reattach the SwiftUI host. Only treat an
    /// `onDisappear` without a matching reappearance as real stream teardown.
    private func scheduleTeardownIfStillAbsent(window: NSWindow?, frame: NSRect?,
                                               generation: Int) {
        DispatchQueue.main.async {
            guard presence.generation == generation else { return }
            exitFullscreenIfNeeded()
            if let window { scheduleWindowRestoration(for: window, frame: frame) }
            if !isRunningInPreview { Task { await controller.disconnect() } }
        }
    }

    private func resizeForWindowedStreamIfNeeded(_ window: NSWindow) {
        guard !controller.startFullscreen, !didResizeForWindowedMode,
              let pixels = controller.streamPixelSize,
              let screen = window.screen ?? NSScreen.main else { return }
        libraryFrame = window.frame
        let contentSize = windowedContentSize(
            pixels: pixels, scale: window.backingScaleFactor,
            minimum: window.contentMinSize, maximum: screen.visibleFrame.size)
        window.setContentSize(contentSize)
        window.center()
        didResizeForWindowedMode = true
    }

    private func windowedContentSize(pixels: PixelSize, scale: CGFloat,
                                     minimum: NSSize, maximum: NSSize) -> NSSize {
        let aspect = CGFloat(pixels.width) / CGFloat(pixels.height)
        var width = max(CGFloat(pixels.width) / scale, minimum.width,
                        minimum.height * aspect)
        var height = width / aspect
        let fit = min(1, maximum.width / width, maximum.height / height)
        width *= fit
        height *= fit
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    /// Changing the style mask rebuilds AppKit's frame view. Avoid a same-value write when the accessor
    /// reattaches during that rebuild, or nested subview enumeration eventually trips an AppKit assertion.
    private func setTitleBarVisible(_ visible: Bool, on window: NSWindow) {
        guard window.styleMask.contains(.titled) != visible else { return }
        if visible {
            window.styleMask.insert(.titled)
        } else {
            window.styleMask.remove(.titled)
        }
    }

    /// Clear the key equivalents of the standard destructive menu commands so they can't fire locally while
    /// streaming full screen; restored on exit.
    private func suppressMenuShortcuts() {
        let blocked: Set<Selector> = [
            #selector(NSApplication.terminate(_:)), #selector(NSApplication.hide(_:)),
            #selector(NSWindow.performClose(_:)), #selector(NSWindow.performMiniaturize(_:)),
        ]
        clearedShortcuts.removeAll()
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let action = item.action, blocked.contains(action), !item.keyEquivalent.isEmpty {
                    clearedShortcuts.append(SavedShortcut(item: item, key: item.keyEquivalent,
                                                          mods: item.keyEquivalentModifierMask))
                    item.keyEquivalent = ""
                }
                if let sub = item.submenu { walk(sub) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu) }
    }

    private func restoreMenuShortcuts() {
        for s in clearedShortcuts {
            s.item.keyEquivalent = s.key
            s.item.keyEquivalentModifierMask = s.mods
        }
        clearedShortcuts.removeAll()
    }

    /// Leave full screen (if we entered it) and return to the library — used from the connection-lost overlay.
    private func exitAndClose() {
        exitFullscreenIfNeeded()
        onClose()
    }
}

private struct StreamToastView: View {
    let toast: StreamToast

    private var icon: String {
        switch toast.category {
        case .adaptiveBitrate: return "gauge.with.dots.needle.bottom.50percent"
        case .audioMuted: return "speaker.slash.fill"
        case .audioUnmuted: return "speaker.wave.2.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(AsteriaTheme.accent, in: .rect(cornerRadius: 8))
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .glassEffect(.regular.tint(streamGlassTint), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(18)
        .transition(.move(edge: .leading).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: toast.id)
        .allowsHitTesting(false)
    }
}

/// Shown only while input is inactive without the menu (window blur / click-out): recapture prompt.
private struct StreamControlsOverlay: View {
    @ObservedObject var capture: StreamInputCapture
    let prompt: String

    var body: some View {
        if !capture.inputActive {
            VStack {
                Spacer()
                Text(prompt)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: .capsule)
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .transition(.opacity)
        }
    }
}

/// Navigable with the mouse, arrow keys, and the controller d-pad/A/B; tap-out resumes. Liquid Glass card.
private struct StreamOverlayMenu: View {
    let controller: StreamController

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controller.closeMenu() }
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 0) {
                    Text(controller.title).font(.title2.weight(.semibold)).foregroundStyle(.white)
                    Text("Paused").font(.caption).foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 2).padding(.bottom, 22)
                    VStack(spacing: 8) {
                        ForEach(Array(controller.menuItems.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == controller.menuSelection)
                        }
                    }
                    .frame(width: 340)
                }
                .padding(28)
                .glassEffect(.regular, in: .rect(cornerRadius: AsteriaTheme.cardCorner))
            }
            .shadow(radius: 30)
        }
    }

    private func row(_ item: StreamController.MenuItem, selected: Bool) -> some View {
        Button(action: item.action) {
            HStack(spacing: 12) {
                Image(systemName: item.icon).frame(width: 22)
                Text(item.title).fontWeight(.medium)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected || item.prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.85)))
            .background(rowFill(selected: selected, prominent: item.prominent), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func rowFill(selected: Bool, prominent: Bool) -> AnyShapeStyle {
        if selected { return AnyShapeStyle(AsteriaTheme.accent) }
        if prominent { return AnyShapeStyle(AsteriaTheme.accent.opacity(0.4)) }
        return AnyShapeStyle(.white.opacity(0.07))
    }
}

#if DEBUG
#Preview("Stream: connecting") {
    StreamContainerView(previewController: .preview(title: "Hades", phase: .connecting))
        .frame(width: 900, height: 560)
}

#Preview("Stream: failed") {
    StreamContainerView(previewController: .preview(
        title: "Hades", phase: .failed("Couldn't reach the PC: connection timed out.")))
        .frame(width: 900, height: 560)
}

#Preview("Stream: connection lost") {
    StreamContainerView(previewController: .preview(title: "Hades", phase: .connectionLost))
        .frame(width: 900, height: 560)
}

#Preview("Stream: overlay menu") {
    let controller = StreamController.preview(title: "Hades", phase: .streaming)
    controller.openMenu()
    return StreamOverlayMenu(controller: controller)
        .frame(width: 900, height: 560)
        .background(.black)
}

#Preview("Stats glass vs. adaptive-quality toast") {
    HStack(alignment: .top, spacing: 24) {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([
                StatLine(label: "FPS", value: "60"),
                StatLine(label: "Loss", value: "0.0%"),
                StatLine(label: "Bitrate", value: "12.4 Mbps"),
                StatLine(label: "Latency", value: "—"),
            ]) { line in
                HStack(spacing: 8) {
                    Text(line.label).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(line.value).foregroundStyle(.white).lineLimit(1)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .frame(width: 190)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .glassEffect(.regular.tint(streamGlassTint), in: .rect(cornerRadius: 12))

        StreamToastView(toast: StreamToast(
            category: .adaptiveBitrate,
            message: "Adaptive bitrate is active in Quality mode."))
    }
    .frame(width: 900, height: 200)
    .background(.black)
}
#endif
