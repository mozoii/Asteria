import SwiftUI
import AsteriaKit

/// Shared glass tint so in-stream surfaces read the same over video.
let streamGlassTint = Color.black.opacity(0.5)

/// Full-bleed live stream: connects on appear, presents the video layer, and routes hotkeys.
///
/// Everything that depends on how the platform frames a stream — window level and full screen on
/// macOS, scene phase and orientation on iOS — lives behind `streamWindowChrome`, which also owns
/// the transition out of the stream so each platform can unwind its own chrome first.
struct StreamContainerView: View {
    @State private var controller: StreamController
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
        .task { if !isRunningInPreview { await controller.connect() } }
        .streamWindowChrome(controller: controller, onClose: onClose)
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
                Button("Back to library") { onClose() }
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
                    .streamTouchControls(controller: controller)
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
        #if os(macOS)
        var parts = ["Click to capture input"]
        #else
        var parts = ["Tap to capture input"]
        #endif
        if let menu = keybindings.keyboard[.toggleOverlayMenu], !menu.isEmpty {
            parts.append("\(menu.displayString) for menu")
        }
        return parts.joined(separator: " · ")
    }
}

struct StreamToastView: View {
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

/// Navigable with the pointer, arrow keys, and the controller d-pad/A/B; tap-out resumes. Liquid Glass card.
struct StreamOverlayMenu: View {
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
