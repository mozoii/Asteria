import SwiftUI
import Foundation
import Combine
import AppKit
@preconcurrency import GameController
import AsteriaKit

/// Sectioned settings — section rail, Global/PC scope switch, two-column panels; controller- and keyboard-drivable.
struct SettingsView: View {
    @State private var store: SettingsEditor
    @State private var section: DeckSection = .video
    @State private var customEntry: CustomEntry?
    @State private var recording: RecordingTarget?
    @State private var hasPlayStationController = false
    @State private var controllerBatteryPercentage: Int?
    @State private var controllerIsCharging = false
    @State private var ledColorPicker = PlayStationLEDColorPicker()
    @StateObject private var nav = ControllerNavReader()
    @State private var deck = SettingsDeckNavigator()
    var onClose: () -> Void

    private struct ControllerBattery {
        let percentage: Int
        let isCharging: Bool
    }

    init(scope: SettingsEditor.Scope, library: HostListStore,
         onClose: @escaping () -> Void) {
        _store = State(initialValue: SettingsEditor(
            scope: scope,
            library: library
        ))
        self.onClose = onClose
    }

    #if DEBUG
    init(previewStore: SettingsEditor,
         section: DeckSection = .video, onClose: @escaping () -> Void = {}) {
        _store = State(initialValue: previewStore)
        _section = State(initialValue: section)
        self.onClose = onClose
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            rail
            content
            Spacer(minLength: 0)
            ControllerHintBar(hints: hints)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AsteriaTheme.background)
        .foregroundStyle(.white)
        .onExitCommand { onClose() }
        .onAppear {
            refreshControllerAvailability()
            applyPlayStationLEDColor(store.inputPreferences.playStationLEDColor)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            refreshControllerAvailability()
            applyPlayStationLEDColor(store.inputPreferences.playStationLEDColor)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            refreshControllerAvailability()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshControllerAvailability()
        }
        .controllerNavigation(nav, focusFirst: focusFirstIfController, drain: drainNav, move: keyboardMove)
        .onChange(of: hasPlayStationController) { _, available in
            if !available, deck.openMenuLabel == "Emulation mode" { deck.closeMenu() }
            if nav.isConnected { syncHighlight() }
        }
        .onChange(of: section) { _, _ in if nav.isConnected { syncHighlight() } }   // keep the controller highlight valid across section changes
        // Switching to (or up to) the display's native resolution makes MetalFX inapplicable — clear the toggle.
        .onChange(of: store.draft.resolution) { _, _ in
            if metalFXTarget == nil { store.draft.enableMetalFX = false }
        }
        // HDR implies 10-bit and HEVC — clamp applies the invariant; don't re-derive it here.
        .onChange(of: store.draft.hdr) { _, on in
            if on { store.draft = store.capabilities.clamp(store.draft) }
        }
        .onChange(of: store.draft) { _, _ in Task { await store.commitStream() } }
        .onChange(of: store.customizeForHost) { _, _ in Task { await store.commitStream() } }
        .onChange(of: store.inputPreferences) { _, _ in Task { await store.commitInput() } }
        .onChange(of: store.inputPreferences.playStationLEDColor) { _, color in
            applyPlayStationLEDColor(color)
        }
        .onChange(of: store.overlayPreferences) { _, _ in Task { await store.commitOverlay() } }
        .sheet(item: $customEntry) { entry in
            CustomEntrySheet(entry: entry, store: store) {
                customEntry = nil
            }
        }
        .sheet(item: $recording, onDismiss: { nav.rearm() }) { target in
            ChordRecorderSheet(target: target, input: store) { recording = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button { onClose() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 38)
                .background(AsteriaTheme.surface, in: .rect(cornerRadius: 11))
            }
            .buttonStyle(.plain)
            .controllerFocusRing(highlight == .back, radius: 11)

            VStack(alignment: .leading, spacing: 3) {
                Text("Settings").font(.system(size: 28, weight: .bold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showScopeSwitch { scopeSwitch }
        }
        .padding(.horizontal, 40).padding(.top, 26).padding(.bottom, 8)
    }

    private var subtitle: String? {
        if section.supportsPerHost { return store.scope.isHost ? store.scope.title : nil }
        if section == .appearance { return "Stats overlay and in-stream notification settings" }
        if section == .input { return "Keyboard, mouse and controller settings that apply to all your PCs" }
        return nil
    }

    private var showScopeSwitch: Bool { section.supportsPerHost && store.scope.isHost }

    private var scopeSwitch: some View {
        HStack(spacing: 4) {
            scopeSegment("Global defaults", isThisPC: false, active: !store.customizeForHost) {
                store.customizeForHost = false
            }
            scopeSegment("This PC", isThisPC: true, active: store.customizeForHost) {
                store.customizeForHost = true
            }
        }
        .padding(4)
        .background(AsteriaTheme.pillTrack, in: .capsule)
    }

    private func scopeSegment(_ title: String, isThisPC: Bool, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.55))
                .padding(.horizontal, 18).frame(height: 34)
                .background(active ? AsteriaTheme.accent : .clear, in: .capsule)
        }
        .buttonStyle(.plain)
        .controllerFocusRing(highlight == .scope(isThisPC), radius: 17)
    }

    private var rail: some View {
        HStack(spacing: 12) {
            ForEach(DeckSection.allCases) { item in
                let isSelected = item == section
                Button { select(section: item) } label: {
                    Text(item.title)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
                        .padding(.horizontal, 16).frame(height: 40)
                        .background(isSelected ? AsteriaTheme.accent : AsteriaTheme.surface, in: .rect(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .controllerFocusRing(highlight == .section(item.rawValue), radius: 11)
            }
            Spacer()
        }
        .padding(.horizontal, 40).padding(.vertical, 10)
    }

    private var hints: [ControllerHint] {
        var h: [ControllerHint] = [
            ControllerHint(glyph: .a, label: "Change"),
            ControllerHint(glyph: .b, label: "Back"),
        ]
        if canResetHighlight { h.append(ControllerHint(glyph: .y, label: "Reset")) }
        h.append(ControllerHint(glyph: .shoulders, label: "Section"))
        h.append(ControllerHint(glyph: .dpad, label: "Move"))
        return h
    }

    /// True when Y would do something on the current highlight: clear a keybind, or revert a per-host field.
    private var canResetHighlight: Bool {
        guard case let .control(label)? = highlight else { return false }
        if let (action, kind) = parseKeybindFocus(label) {
            return !(kind == .gamepad ? store.gamepadChord(for: action).isEmpty
                                      : store.keyChord(for: action).isEmpty)
        }
        return showScopeSwitch && store.customizeForHost
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch section {
                    case .video:
                        columns(left: { videoLeft }, right: { videoRight })
                        legend
                    case .audio:
                        columns(left: { audioLeft }, right: { EmptyView() })
                        legend
                    case .host:
                        columns(left: { hostLeft }, right: { EmptyView() })
                        legend
                    case .input:
                        columns(left: { inputLeft }, right: { inputRight })
                    case .appearance:
                        columns(left: { appearanceLeft }, right: { EmptyView() })
                    case .about:
                        AboutSettingsSection()
                    }
                }
                .padding(.horizontal, 40).padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Keep the controller/keyboard-highlighted row on screen as navigation moves down a column.
            .onChange(of: highlight) { _, h in
                guard let h, case .control = h else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(h, anchor: .center) }
            }
        }
    }

    private func columns<L: View, R: View>(@ViewBuilder left: () -> L, @ViewBuilder right: () -> R) -> some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(spacing: 18) { left() }.frame(maxWidth: .infinity, alignment: .top)
            VStack(spacing: 18) { right() }.frame(maxWidth: .infinity, alignment: .top)
        }
        .disabled(inheriting).opacity(inheriting ? 0.4 : 1)
    }

    private var inheriting: Bool {
        section.supportsPerHost && store.scope.isHost && !store.customizeForHost
    }

    private func ov(_ differs: Bool) -> Bool { showScopeSwitch && store.customizeForHost && differs }

    @ViewBuilder private var legend: some View {
        if showScopeSwitch && store.customizeForHost {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(AsteriaTheme.accent).frame(width: 3, height: 16)
                Text("Overridden for this PC. Press Y to reset to the global default")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func row<Control: View>(_ label: String, focus: String? = nil, subtitle: String? = nil,
                                    subtitleWarning: Bool = false, subtitleAccent: Bool = false,
                                    dimmed: Bool = false, overridden: Bool = false,
                                    @ViewBuilder control: @escaping () -> Control) -> some View {
        DeckRow(label, focus: focus, subtitle: subtitle, subtitleWarning: subtitleWarning,
                subtitleAccent: subtitleAccent, dimmed: dimmed, overridden: overridden,
                highlight: highlight, control: control)
            .id(SettingsFocus.control(focus ?? label))
    }

    private var g: StreamSettings { store.globalSettings }

    @ViewBuilder private var videoLeft: some View {
        Panel("Window") {
            row("Display mode", subtitle: "How streams open.",
                overridden: ov(store.draft.windowMode != g.windowMode)) {
                menuView("Display mode", store.draft.windowMode.deckName)
            }
            row("Hide title bar",
                subtitle: "Removes the title bar and window controls while streaming. Windowed mode only.",
                dimmed: store.draft.windowMode != .windowed,
                overridden: ov(store.draft.hideTitleBarInWindowedMode
                    != g.hideTitleBarInWindowedMode)) {
                DeckCheckbox(isOn: $store.draft.hideTitleBarInWindowedMode,
                             enabled: store.draft.windowMode == .windowed)
            }
        }
        Panel("Display") {
            row("Resolution", overridden: ov(store.draft.resolution != g.resolution)) { menuView("Resolution", resolutionLabel) }
            row("Frame rate", overridden: ov(store.draft.frameRate != g.frameRate)) { menuView("Frame rate", frameRateLabel) }
            row("Enable MetalFX", subtitle: metalFXSubtitle, subtitleAccent: metalFXActive,
                dimmed: metalFXTarget == nil,
                overridden: ov(store.draft.enableMetalFX != g.enableMetalFX)) {
                DeckCheckbox(isOn: $store.draft.enableMetalFX, enabled: metalFXTarget != nil)
            }
        }
    }

    @ViewBuilder private var videoRight: some View {
        Panel("Bandwidth") {
            row("Bitrate", overridden: ov(store.draft.bitrate != g.bitrate)) { menuView("Bitrate", bitrateLabel) }
            if store.draft.bitrate.isAdaptive {
                row("Adaptive mode", subtitle: adaptiveHint, subtitleAccent: adaptiveUnconfirmed,
                    overridden: ov(store.draft.adaptiveMode != g.adaptiveMode)) {
                    menuView("Adaptive mode", store.draft.adaptiveMode.displayName)
                }
                .onAppear { store.probeAdaptiveSupportIfNeeded() }
            }
        }
        Panel("Encoding") {
            row("Codec", overridden: ov(store.draft.codec != g.codec)) { menuView("Codec", store.draft.codec.deckName) }
            row("Color depth", focus: "Bit depth", subtitle: bitDepthHint, dimmed: store.draft.hdr,
                overridden: ov(store.draft.bitDepth != g.bitDepth)) {
                if store.draft.hdr {
                    Text("10-bit").font(.system(size: 13)).foregroundStyle(.secondary)   // HDR owns bit depth
                } else {
                    menuView("Bit depth", store.draft.bitDepth.deckName)
                }
            }
            row("HDR", subtitle: hdrHint, dimmed: !hdrAvailable,
                overridden: ov(store.draft.hdr != g.hdr)) {
                DeckCheckbox(isOn: $store.draft.hdr, enabled: hdrAvailable)
            }
        }
    }

    private var bitDepthHint: String {
        if store.draft.hdr { return "HDR requires the stream to be in 10-bit." }
        return store.capabilities.supportsTenBit
            ? "10-bit reduces banding, rendered to SDR."
            : "This Mac's decoder doesn't support 10-bit."
    }

    /// HDR needs the HDR display + 10-bit decoder AND HEVC available, since HDR is carried only over HEVC.
    private var hdrAvailable: Bool {
        store.capabilities.supportsHDR && store.capabilities.allows(codec: .hevc)
    }

    private var hdrHint: String {
        store.capabilities.supportsHDR
            ? "Brighter highlights and richer colors on HDR-capable displays."
            : "Requires a display that supports HDR."
    }

    @ViewBuilder private var audioLeft: some View {
        Panel("Output") {
            row("Channels", subtitle: "Surround is downmixed when your output is stereo.",
                overridden: ov(store.draft.audio != g.audio)) { menuView("Channels", store.draft.audio.deckName) }
            row("Play audio on host", subtitle: "Audio keeps playing on the PC instead of streaming to this Mac.",
                overridden: ov(store.draft.playAudioOnHost != g.playAudioOnHost)) {
                DeckCheckbox(isOn: $store.draft.playAudioOnHost)
            }
            row("Mute when inactive", subtitle: "Mute stream audio while another app is active.",
                overridden: ov(store.draft.muteWhenInactive != g.muteWhenInactive)) {
                DeckCheckbox(isOn: $store.draft.muteWhenInactive)
            }
        }
    }

    @ViewBuilder private var hostLeft: some View {
        Panel("Behavior") {
            row("Close app on host", subtitle: "Quits the running app on the host after you disconnect.",
                overridden: ov(store.draft.closeAppOnDisconnect != g.closeAppOnDisconnect)) {
                DeckCheckbox(isOn: $store.draft.closeAppOnDisconnect)
            }
            row("Sync clipboard", subtitle: "Sends the current Mac clipboard to the host. *Supported only by Apollo hosts.*",
                overridden: ov(store.draft.syncClipboard != g.syncClipboard)) {
                DeckCheckbox(isOn: $store.draft.syncClipboard)
            }
        }
    }

    @ViewBuilder private var inputLeft: some View {
        Panel("Mouse") {
            row("Mode", subtitle: store.inputPreferences.mouseMode.detail) {
                menuView("Mode", store.inputPreferences.mouseMode.displayName)
            }
            row("Swap mouse buttons", subtitle: "Left and right click are swapped.") {
                DeckCheckbox(isOn: $store.inputPreferences.swapMouseButtons)
            }
        }
        Panel("Keyboard") {
            row("Swap Win / Alt keys", subtitle: "Alt sends Windows, and Windows sends Alt, on the host.") {
                DeckCheckbox(isOn: $store.inputPreferences.swapWinAltKeys)
            }
        }
        Panel("Controller", trailingTitle: controllerBatteryTitle,
              trailingTitleColor: controllerBatteryTitleColor,
              trailingSymbols: controllerBatterySymbols) {
            row("Swap A / B face buttons", subtitle: "For Nintendo-style layouts where B confirms.") {
                DeckCheckbox(isOn: $store.inputPreferences.swapFaceButtons)
            }
            row(
                "Show Battery Percentage",
                subtitle: "Display the battery percentage instead of a battery symbol.") {
                DeckCheckbox(isOn: $store.inputPreferences.showControllerBatteryPercentage)
            }
            if hasPlayStationController {
                row("Emulation mode", subtitle: "Changes apply to new streams only.") {
                    menuView(
                        "Emulation mode",
                        store.inputPreferences.playStationEmulation.displayName
                    )
                }
                row(
                    "LED color",
                    subtitle: "Sets the color of the LED light bar on "
                        + "DualShock/DualSense controllers.") {
                    Button { showPlayStationLEDColorPicker() } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(color(for: store.inputPreferences.playStationLEDColor))
                            .frame(width: 34, height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.white.opacity(0.25))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var inputRight: some View {
        Panel("Keyboard shortcuts") {
            ForEach(StreamAction.allCases) { action in keybindRow(action, kind: .keyboard) }
        }
        Panel("Controller combos") {
            ForEach(StreamAction.allCases) { action in keybindRow(action, kind: .gamepad) }
        }
        resetShortcutsRow
    }

    @ViewBuilder private var appearanceLeft: some View {
        Panel("Stats overlay") {
            row("Network latency", subtitle: "Show the network round-trip.") {
                DeckCheckbox(isOn: $store.overlayPreferences.showNetworkLatency)
            }
            row("Input latency", subtitle: "Show local input delay.") {
                DeckCheckbox(isOn: $store.overlayPreferences.showInputLatency)
            }
            row("Decode latency", subtitle: "Show the frame decode time.") {
                DeckCheckbox(isOn: $store.overlayPreferences.showDecodeLatency)
            }
        }
        Panel("In-stream notifications") {
            row("Adaptive bitrate", subtitle: "Show adaptive bitrate status while streaming.") {
                DeckCheckbox(isOn: $store.overlayPreferences.showAdaptiveBitrateNotifications)
            }
            row("Mute / unmute audio", subtitle: "Show a toast when stream audio is muted or unmuted.") {
                DeckCheckbox(isOn: $store.overlayPreferences.showMuteNotifications)
            }
        }
    }

    /// The chord, its empty state, and any conflicts for one action — plain (non-ViewBuilder) so it can branch.
    private func keybindInfo(_ action: StreamAction, kind: ChordRecorder.Kind)
        -> (display: String, isEmpty: Bool, conflicts: [StreamAction]) {
        switch kind {
        case .keyboard:
            let c = store.keyChord(for: action)
            let conflicts = c.isEmpty ? [] : store.keyboardConflicts(c, for: action)
            return (c.displayString, c.isEmpty, conflicts)
        case .gamepad:
            let c = store.gamepadChord(for: action)
            let conflicts = c.isEmpty ? [] : store.gamepadConflicts(c, for: action)
            return (c.displayString, c.isEmpty, conflicts)
        }
    }

    /// Stable focus id for a keybind row, namespaced by kind so the keyboard and gamepad rows for the same
    /// action can coexist in the merged Input tab without colliding.
    private func keybindFocus(_ action: StreamAction, _ kind: ChordRecorder.Kind) -> String {
        (kind == .keyboard ? "kb:" : "pad:") + action.rawValue
    }

    /// Decode a keybind focus id back to its action + kind, or nil for any non-keybind focus.
    private func parseKeybindFocus(_ id: String) -> (StreamAction, ChordRecorder.Kind)? {
        let kind: ChordRecorder.Kind
        let raw: String
        if id.hasPrefix("kb:") { kind = .keyboard; raw = String(id.dropFirst(3)) }
        else if id.hasPrefix("pad:") { kind = .gamepad; raw = String(id.dropFirst(4)) }
        else { return nil }
        guard let action = StreamAction(rawValue: raw) else { return nil }
        return (action, kind)
    }

    /// One keybind row: the chord keycap, a clear (✕) button, and an inline conflict/description subtitle.
    @ViewBuilder private func keybindRow(_ action: StreamAction, kind: ChordRecorder.Kind) -> some View {
        let info = keybindInfo(action, kind: kind)
        row(action.displayName, focus: keybindFocus(action, kind),
            subtitle: info.conflicts.isEmpty ? action.detail
                : "Already used by " + info.conflicts.map(\.displayName).joined(separator: ", "),
            subtitleWarning: !info.conflicts.isEmpty) {
            HStack(spacing: 8) {
                DeckKeycap(text: info.display) { recording = RecordingTarget(action: action, kind: kind) }
                Button { clearKeybind(action, kind: kind) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).opacity(info.isEmpty ? 0.25 : 1).disabled(info.isEmpty).help("Clear binding")
            }
        }
    }

    private func clearKeybind(_ action: StreamAction, kind: ChordRecorder.Kind) {
        if kind == .keyboard {
            store.setKeyChord(nil, for: action)
        } else {
            store.setGamepadChord(nil, for: action)
        }
    }

    private var resetShortcutsRow: some View {
        HStack {
            Spacer()
            Button { store.resetKeybindings() } label: {
                Text("Reset to defaults")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(AsteriaTheme.pillTrack, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .controllerFocusRing(highlight == .control("reset-shortcuts"), radius: 8)
        }
        .padding(.top, 8)
    }

    private func menuView(_ label: String, _ value: String) -> some View {
        DeckMenu(value, items: menuItems(for: label),
                 isOpen: Binding(get: { deck.openMenuLabel == label },
                                 set: { if $0 { deck.openMenu(label, index: selectedIndex(for: label)) } else { deck.closeMenu() } }),
                 highlightedIndex: deck.openMenuLabel == label ? deck.menuIndex : nil)
    }

    /// The single source of truth for each menu's options — used both by the view and by controller activation.
    private func menuItems(for label: String) -> [DeckMenuItem] {
        switch label {
        case "Resolution":
            return store.capabilities.resolutionPresets.map { size in
                let resolution = VideoResolution.preset(width: size.width, height: size.height)
                return DeckMenuItem(resolutionTag(size),
                                    detail: "\(size.width) × \(size.height)",
                                    selected: isResolutionPreset(size)) {
                    store.draft.resolution = resolution
                }
            } + [
                DeckMenuItem("Match Mac", detail: "Native resolution",
                             selected: store.draft.resolution == .matchDisplay) {
                    store.draft.resolution = .matchDisplay
                },
                DeckMenuItem("Custom", detail: "Enter dimensions",
                             selected: isResolutionCustom) { customEntry = .resolution },
            ]
        case "Frame rate":
            return store.capabilities.frameRatePresets.map { fps in
                let frameRate = FrameRate.fps(fps)
                return DeckMenuItem("\(fps)", selected: store.draft.frameRate == frameRate) {
                    store.draft.frameRate = frameRate
                }
            } + [
                DeckMenuItem("Match display", selected: store.draft.frameRate == .matchDisplay) {
                    store.draft.frameRate = .matchDisplay
                },
                DeckMenuItem("Manual", selected: isFrameRateCustom) { customEntry = .frameRate },
            ]
        case "Bitrate":
            return [
                DeckMenuItem("Auto", selected: isBitrateAuto) { store.draft.bitrate = .auto },
                DeckMenuItem("Adaptive", selected: store.draft.bitrate.isAdaptive) { store.draft.bitrate = .adaptive },
                DeckMenuItem("Manual", selected: isBitrateManual) { customEntry = .bitrate },
            ]
        case "Adaptive mode":
            return AdaptiveMode.allCases.map { mode in
                DeckMenuItem(mode.displayName, selected: store.draft.adaptiveMode == mode) {
                    store.draft.adaptiveMode = mode
                }
            }
        case "Codec":
            return store.capabilities.codecChoices.map { choice in
                // The HDR→HEVC rule lives in allowsCodec — don't re-derive it here.
                let enabled = store.capabilities.allowsCodec(choice.codec, whenHDR: store.draft.hdr)
                return DeckMenuItem(choice.codec.deckName, selected: store.draft.codec == choice.codec, enabled: enabled) {
                    store.draft.codec = choice.codec
                }
            }
        case "Bit depth":
            if store.draft.hdr { return [] }   // HDR forces 10-bit; the row is a static value, not a menu
            return [
                DeckMenuItem("8-bit", selected: store.draft.bitDepth == .eightBit) { store.draft.bitDepth = .eightBit },
                DeckMenuItem("10-bit", selected: store.draft.bitDepth == .preferTenBit,
                             enabled: store.capabilities.supportsTenBit) {
                    store.draft.bitDepth = .preferTenBit
                },
            ]
        case "Channels":
            return store.capabilities.audio.map { ch in
                DeckMenuItem(ch.deckName, selected: store.draft.audio == ch) { store.draft.audio = ch }
            }
        case "Mode":
            return MouseMode.allCases.map { mode in
                DeckMenuItem(
                    mode.displayName,
                    selected: store.inputPreferences.mouseMode == mode
                ) {
                    store.inputPreferences.mouseMode = mode
                }
            }
        case "Emulation mode":
            return PlayStationControllerEmulation.allCases.map { mode in
                DeckMenuItem(
                    mode.displayName,
                    selected: store.inputPreferences.playStationEmulation == mode
                ) {
                    store.inputPreferences.playStationEmulation = mode
                }
            }
        case "Display mode":
            return WindowMode.allCases.map { mode in
                DeckMenuItem(mode.deckName, selected: store.draft.windowMode == mode) { store.draft.windowMode = mode }
            }
        default:
            return []
        }
    }

    private func selectedIndex(for label: String) -> Int {
        menuItems(for: label).firstIndex(where: \.selected) ?? 0
    }

    private var resolutionLabel: String {
        switch store.draft.resolution {
        case let .preset(w, h): return resolutionTag(PixelSize(width: w, height: h))
        case let .custom(w, h): return "\(w) × \(h)"
        case .matchDisplay: return "Match Mac"
        }
    }

    /// Short standard tag for a size ("1080p", "4K"), falling back to dimensions for non-standard modes.
    private func resolutionTag(_ size: PixelSize) -> String {
        switch size.height {
        case 720: return "720p"
        case 1080: return "1080p"
        case 1440: return "1440p"
        case 2160: return "4K"
        default: return "\(size.width) × \(size.height)"
        }
    }

    /// The display MetalFX would upscale to for the current draft resolution, or nil when it can't help.
    private var metalFXTarget: PixelSize? { store.capabilities.metalFXTarget(for: store.draft.resolution) }

    /// MetalFX is both eligible and switched on — used to distinctively surface the upscale in the subtitle.
    private var metalFXActive: Bool { metalFXTarget != nil && store.draft.enableMetalFX }

    /// Either the from→to upscale (when active), why it's unavailable, or the plain description.
    private var metalFXSubtitle: String {
        guard let target = metalFXTarget else {
            return store.capabilities.displaySize == nil
                ? "This Mac's display resolution is unknown."
                : "The stream resolution already matches your display."
        }
        if store.draft.enableMetalFX,
           let from = store.draft.resolution.dimensions(matchingDisplay: store.capabilities.displaySize) {
            return "Upscaling \(resolutionTag(from)) to \(resolutionTag(target))"
        }
        return "Upscales the stream to your display resolution for increased visual quality."
    }

    private func isResolutionPreset(_ size: PixelSize) -> Bool {
        if case let .preset(w, h) = store.draft.resolution { return w == size.width && h == size.height }
        return false
    }

    private var isResolutionCustom: Bool {
        if case .custom = store.draft.resolution { return true }
        return false
    }

    private var frameRateLabel: String {
        switch store.draft.frameRate {
        case let .fps(v): return "\(v)"
        case .matchDisplay: return "Match display"
        }
    }

    private var isFrameRateCustom: Bool {
        if case let .fps(v) = store.draft.frameRate { return !store.capabilities.frameRatePresets.contains(v) }
        return false
    }

    private var isBitrateAuto: Bool { if case .auto = store.draft.bitrate { return true }; return false }
    private var isBitrateManual: Bool { if case .manual = store.draft.bitrate { return true }; return false }

    private var bitrateLabel: String {
        switch store.draft.bitrate {
        case .auto: return "Auto · ≈ \(MbpsFormat.string(store.recommendedBitrateKbps)) Mbps"
        case .adaptive: return "Adaptive · up to ≈ \(MbpsFormat.string(store.recommendedBitrateKbps)) Mbps"
        case let .manual(kbps): return "\(MbpsFormat.string(kbps)) Mbps"
        }
    }

    /// The pre-stream probe couldn't confirm support — not proof it's missing (older hosts still accept the
    /// live request), so this only softens the wording, it doesn't disable Adaptive.
    private var adaptiveUnconfirmed: Bool { store.hostSupportsAdaptive == false }

    private var adaptiveHint: String {
        if adaptiveUnconfirmed {
            return "Couldn't confirm this PC supports adaptive quality. It'll be used if the PC accepts it; otherwise the stream stays at the Auto rate."
        }
        return "Automatically lowers video quality when your connection is busy and raises it again once it clears. Prefer Quality keeps the picture sharper; Prefer Latency reacts faster to stay responsive."
    }

    /// The controller/keyboard highlight, derived from the navigator's cursor over the live layout.
    private var highlight: SettingsFocus? { deck.highlight }

    private var chromeTargets: [SettingsFocus] {
        var t: [SettingsFocus] = [.back]
        if section.supportsPerHost && store.scope.isHost { t += [.scope(false), .scope(true)] }
        return t
    }

    /// The left/right control columns mirror the side-by-side panels (Video: Display+Encoding | Bandwidth+Playback).
    private func leftControls(for s: DeckSection) -> [String] {
        switch s {
        case .video: return ["Display mode", "Resolution", "Frame rate", "Enable MetalFX"]
        case .audio: return ["Channels", "Play audio on host", "Mute when inactive"]
        case .host: return ["Close app on host", "Sync clipboard"]
        case .input:
            var controls = ["Mode", "Swap mouse buttons", "Swap Win / Alt keys",
                            "Swap A / B face buttons", "Show Battery Percentage"]
            if hasPlayStationController { controls += ["Emulation mode", "LED color"] }
            return controls
        case .appearance:
            return ["Network latency", "Input latency", "Decode latency", "Adaptive bitrate"]
        case .about: return []
        }
    }

    private func rightControls(for s: DeckSection) -> [String] {
        switch s {
        case .video:
            let adaptive = store.draft.bitrate.isAdaptive ? ["Adaptive mode"] : []
            return ["Bitrate"] + adaptive + ["Codec", "Bit depth", "HDR"]
        case .audio, .host, .appearance: return []
        case .input:
            return StreamAction.allCases.map { keybindFocus($0, .keyboard) }
                + StreamAction.allCases.map { keybindFocus($0, .gamepad) }
                + ["reset-shortcuts"]
        case .about: return []
        }
    }

    /// Snapshot the live layout the navigator reasons over for the current section.
    private func layout() -> DeckLayout {
        DeckLayout(chrome: chromeTargets, sectionId: section.rawValue,
                   left: leftControls(for: section), right: rightControls(for: section),
                   inheriting: inheriting)
    }

    private func syncHighlight() { deck.syncHighlight(layout()) }

    /// Mouse path for the section rail — just switch; `onChange(section)` re-clamps the controller highlight.
    private func select(section newSection: DeckSection) { section = newSection }

    private func refreshControllerAvailability() {
        let controllers = GCController.controllers()
        hasPlayStationController = controllers.contains(where: \.isPlayStationController)
        let battery = controllers.compactMap { controllerBattery(for: $0) }.first
        controllerBatteryPercentage = battery?.percentage
        controllerIsCharging = battery?.isCharging ?? false
    }

    private func controllerBattery(for controller: GCController) -> ControllerBattery? {
        guard let battery = controller.battery, battery.batteryState != .unknown else { return nil }
        let percentage = Int(max(0, min(1, battery.batteryLevel)) * 100)
        return ControllerBattery(
            percentage: percentage,
            isCharging: battery.batteryState == .charging
        )
    }

    private var controllerBatterySymbols: [String] {
        guard let percentage = controllerBatteryPercentage else { return [] }
        guard !store.inputPreferences.showControllerBatteryPercentage else {
            return ["gamecontroller.fill"]
        }
        return ["gamecontroller.fill", Self.batterySymbol(for: percentage)]
    }

    private var controllerBatteryTitle: String? {
        guard store.inputPreferences.showControllerBatteryPercentage,
              let percentage = controllerBatteryPercentage else { return nil }
        return "\(percentage)%"
    }

    private var controllerBatteryTitleColor: Color? {
        guard store.inputPreferences.showControllerBatteryPercentage,
              controllerBatteryPercentage != nil,
              controllerIsCharging else { return nil }
        return .green
    }

    private static func batterySymbol(for percentage: Int) -> String {
        switch percentage {
        case ..<25: return "battery.0"
        case ..<50: return "battery.25"
        case ..<75: return "battery.50"
        case ..<100: return "battery.75"
        default: return "battery.100"
        }
    }

    private func showPlayStationLEDColorPicker() {
        let color = store.inputPreferences.playStationLEDColor
        ledColorPicker.present(color: nsColor(for: color)) { color in
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            store.inputPreferences.playStationLEDColor = PlayStationLEDColor(
                red: Self.colorByte(rgb.redComponent),
                green: Self.colorByte(rgb.greenComponent),
                blue: Self.colorByte(rgb.blueComponent),
                opacity: Self.colorByte(rgb.alphaComponent))
        }
    }

    private func color(for color: PlayStationLEDColor) -> Color {
        Color(red: Double(color.red) / 255, green: Double(color.green) / 255,
              blue: Double(color.blue) / 255)
            .opacity(Double(color.opacity) / 255)
    }

    private func nsColor(for color: PlayStationLEDColor) -> NSColor {
        NSColor(red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.opacity) / 255)
    }

    private func applyPlayStationLEDColor(_ color: PlayStationLEDColor) {
        let controllers = GCController.controllers()
        for controller in controllers where controller.isPlayStationController {
            guard let light = controller.light else { continue }
            light.color = GCColor(red: Float(color.red) / 255 * color.brightness,
                                  green: Float(color.green) / 255 * color.brightness,
                                  blue: Float(color.blue) / 255 * color.brightness)
        }
    }

    private static func colorByte(_ value: CGFloat) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded())
    }

    private func switchSection(_ delta: Int) {
        let all = DeckSection.allCases
        guard let i = all.firstIndex(of: section) else { return }
        section = all[min(max(0, i + delta), all.count - 1)]
    }

    private func focusFirstIfController() {
        guard nav.isConnected else { return }
        focusFirst()
    }

    private func focusFirst() { deck.focusFirst(layout()) }

    /// True while a typed-entry or rebind sheet owns the screen — pause menu navigation.
    private var navBlocked: Bool { customEntry != nil || recording != nil }

    private func drainNav() {
        if navBlocked { nav.flush(); return }
        while let dir = nav.dequeue() { apply(dir) }
    }

    /// Keyboard arrow/Return navigation, sharing the controller's directional model and the same guards.
    private func keyboardMove(_ dir: ControllerNavReader.Dir) {
        guard !navBlocked else { return }
        if highlight == nil { focusFirst() } else { apply(dir) }
    }

    private func apply(_ dir: ControllerNavReader.Dir) {
        if deck.openMenuLabel != nil { applyMenu(dir); return }
        let move: NavDir
        switch dir {
        case .up: move = .up
        case .down: move = .down
        case .left: move = .left
        case .right: move = .right
        case .prevSection: move = .prevSection
        case .nextSection: move = .nextSection
        case .activate: activateFocused(); return
        case .reset: resetHighlighted(); return                 // Y → clear keybind / revert per-host field
        case .back: onClose(); return
        case .options: return
        }
        if case let .switchSection(delta) = deck.move(move, layout()) {
            switchSection(delta); syncHighlight()
        }
    }

    /// In-place navigation of an open dropdown — up/left previous, down/right next, A confirms, B closes.
    private func applyMenu(_ dir: ControllerNavReader.Dir) {
        guard let label = deck.openMenuLabel else { return }
        let items = menuItems(for: label)
        switch dir {
        case .up, .left: deck.stepMenu(-1, itemCount: items.count)
        case .down, .right: deck.stepMenu(1, itemCount: items.count)
        case .activate:
            // Dismiss first, run next runloop so Custom…/Manual sheet presents outside CA-commit.
            if items.indices.contains(deck.menuIndex), items[deck.menuIndex].enabled {
                let perform = items[deck.menuIndex].action
                deck.closeMenu()
                Task { @MainActor in perform() }
            } else {
                deck.closeMenu()
            }
        case .back: deck.closeMenu()
        case .options, .reset, .prevSection, .nextSection: break
        }
    }

    /// Perform the highlighted control's action — the reader owns activation (the system focus engine is off).
    private func activateFocused() {
        switch highlight {
        case .back: onClose()
        case let .scope(isThisPC): store.customizeForHost = isThisPC
        case .section: break   // tabs switch via left/right; there's nothing to "activate" on a tab
        case let .control(label): activateControl(label)
        case .none: break
        }
    }

    private func activateControl(_ label: String) {
        // Match the mouse path: video/audio controls are disabled while a host inherits global defaults.
        if inheriting { return }
        if !menuItems(for: label).isEmpty {          // a dropdown — open it for in-place navigation
            deck.openMenu(label, index: selectedIndex(for: label))
            return
        }
        switch label {
        case "Enable MetalFX":
            if metalFXTarget != nil { store.draft.enableMetalFX.toggle() }
        case "HDR":
            if hdrAvailable { store.draft.hdr.toggle() }
        case "Mute when inactive": store.draft.muteWhenInactive.toggle()
        case "Play audio on host": store.draft.playAudioOnHost.toggle()
        case "Hide title bar":
            if store.draft.windowMode == .windowed {
                store.draft.hideTitleBarInWindowedMode.toggle()
            }
        case "Close app on host": store.draft.closeAppOnDisconnect.toggle()
        case "Sync clipboard": store.draft.syncClipboard.toggle()
        case "Swap mouse buttons": store.inputPreferences.swapMouseButtons.toggle()
        case "Swap Win / Alt keys": store.inputPreferences.swapWinAltKeys.toggle()
        case "Swap A / B face buttons": store.inputPreferences.swapFaceButtons.toggle()
        case "Show Battery Percentage":
            store.inputPreferences.showControllerBatteryPercentage.toggle()
        case "LED color": showPlayStationLEDColorPicker()
        case "Network latency": store.overlayPreferences.showNetworkLatency.toggle()
        case "Input latency": store.overlayPreferences.showInputLatency.toggle()
        case "Decode latency": store.overlayPreferences.showDecodeLatency.toggle()
        case "reset-shortcuts": store.resetKeybindings()
        default:
            if let (action, kind) = parseKeybindFocus(label) {
                recording = RecordingTarget(action: action, kind: kind)
            }
        }
    }

    /// Y: clear a keybind or revert a per-host field; a no-op otherwise.
    private func resetHighlighted() {
        guard case let .control(label)? = highlight else { return }
        if let (action, kind) = parseKeybindFocus(label) {
            clearKeybind(action, kind: kind)
            return
        }
        guard showScopeSwitch && store.customizeForHost else { return }
        switch label {
        case "Resolution": store.draft.resolution = g.resolution
        case "Frame rate": store.draft.frameRate = g.frameRate
        case "Codec": store.draft.codec = g.codec
        case "Bit depth": store.draft.bitDepth = g.bitDepth
        case "HDR": store.draft.hdr = g.hdr
        case "Bitrate": store.draft.bitrate = g.bitrate
        case "Adaptive mode": store.draft.adaptiveMode = g.adaptiveMode
        case "Enable MetalFX": store.draft.enableMetalFX = g.enableMetalFX
        case "Display mode": store.draft.windowMode = g.windowMode
        case "Hide title bar":
            store.draft.hideTitleBarInWindowedMode = g.hideTitleBarInWindowedMode
        case "Channels": store.draft.audio = g.audio
        case "Mute when inactive": store.draft.muteWhenInactive = g.muteWhenInactive
        case "Play audio on host": store.draft.playAudioOnHost = g.playAudioOnHost
        case "Close app on host": store.draft.closeAppOnDisconnect = g.closeAppOnDisconnect
        case "Sync clipboard": store.draft.syncClipboard = g.syncClipboard
        default: break
        }
    }
}

enum DeckSection: String, CaseIterable, Identifiable {
    case video, audio, input, host, appearance, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .host: return "Host"
        case .input: return "Input"
        case .appearance: return "Appearance"
        case .about: return "About"
        }
    }
    var supportsPerHost: Bool { self == .video || self == .audio || self == .host }
}

private struct Panel<Content: View>: View {
    let title: String
    let trailingTitle: String?
    let trailingTitleColor: Color?
    let trailingSymbols: [String]
    @ViewBuilder var content: () -> Content
    init(_ title: String, trailingTitle: String? = nil, trailingTitleColor: Color? = nil,
         trailingSymbols: [String] = [], @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailingTitle = trailingTitle
        self.trailingTitleColor = trailingTitleColor
        self.trailingSymbols = trailingSymbols
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                if trailingTitle != nil || !trailingSymbols.isEmpty {
                    HStack(spacing: 6) {
                        VStack(alignment: .center, spacing: 2) {
                            ForEach(trailingSymbols, id: \.self) { symbol in
                                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                                    .frame(width: 16, alignment: .center)
                            }
                        }
                        if let trailingTitle {
                            Text(trailingTitle)
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(trailingTitleColor ?? .secondary)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 16).padding(.horizontal, 20)
            Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 20).padding(.top, 12)
            VStack(spacing: 0) { content() }.padding(.horizontal, 14).padding(.vertical, 6)
        }
        .background(AsteriaTheme.surface, in: .rect(cornerRadius: AsteriaTheme.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: AsteriaTheme.cardCorner).strokeBorder(.white.opacity(0.08)))
    }
}

private struct DeckRow<Control: View>: View {
    let label: String
    /// Navigation identity, distinct from `label` so a friendlier display name can key to a stable control id.
    let focus: String
    var subtitle: String?
    var subtitleWarning: Bool
    var subtitleAccent: Bool
    var dimmed: Bool
    var overridden: Bool
    var highlight: SettingsFocus?
    @ViewBuilder var control: () -> Control

    init(_ label: String, focus: String? = nil, subtitle: String? = nil, subtitleWarning: Bool = false,
         subtitleAccent: Bool = false, dimmed: Bool = false, overridden: Bool = false, highlight: SettingsFocus?,
         @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.focus = focus ?? label
        self.subtitle = subtitle
        self.subtitleWarning = subtitleWarning
        self.subtitleAccent = subtitleAccent
        self.dimmed = dimmed
        self.overridden = overridden
        self.highlight = highlight
        self.control = control
    }

    private var isFocused: Bool { highlight == .control(focus) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 15, weight: .medium))
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(.system(size: 11, weight: subtitleAccent ? .semibold : .regular))
                        .foregroundStyle(subtitleWarning ? Color.orange
                            : subtitleAccent ? AsteriaTheme.accent : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control()
        }
        // Dim the whole row (label, subtitle, control) when the setting can't apply here.
        .opacity(dimmed ? 0.4 : 1)
        .padding(.horizontal, 6)
        .frame(minHeight: 54)
        .background(isFocused ? AsteriaTheme.surfaceFocused : .clear, in: .rect(cornerRadius: 10))
        // Override indicator sits in the gutter so the label stays aligned with the section header.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(AsteriaTheme.accent)
                .frame(width: 3, height: 22).opacity(overridden ? 1 : 0).offset(x: -2)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 10).strokeBorder(AsteriaTheme.accent.opacity(0.7), lineWidth: 1.5)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
    }
}

private let popSurface = Color(red: 0.067, green: 0.086, blue: 0.110)

struct DeckMenuItem: Identifiable {
    var id: String { label }   // stable within a menu (labels are unique) — keeps ForEach identity across renders
    let label: String
    let detail: String?
    let selected: Bool
    var enabled: Bool
    let action: () -> Void
    init(_ label: String, detail: String? = nil, selected: Bool,
         enabled: Bool = true, action: @escaping () -> Void) {
        self.label = label
        self.detail = detail
        self.selected = selected
        self.enabled = enabled
        self.action = action
    }
}

/// Custom dark dropdown (pill + popover list). Dismiss first, run next runloop so Custom…/Manual… sheet avoids popover CA-commit.
struct DeckMenu: View {
    let valueLabel: String
    let items: [DeckMenuItem]
    @Binding var isOpen: Bool
    var highlightedIndex: Int?

    init(_ valueLabel: String, items: [DeckMenuItem], isOpen: Binding<Bool>, highlightedIndex: Int? = nil) {
        self.valueLabel = valueLabel
        self.items = items
        self._isOpen = isOpen
        self.highlightedIndex = highlightedIndex
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 8) {
                Text(valueLabel).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(height: 38)
            .background(AsteriaTheme.pillTrack, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.14)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        isOpen = false
                        let perform = item.action
                        Task { @MainActor in perform() }
                    } label: {
                        HStack(spacing: 12) {
                            Text(item.label).font(.system(size: 14, weight: item.selected ? .semibold : .regular))
                                .foregroundStyle(item.selected ? Color.white : Color.white.opacity(0.82))
                            Spacer()
                            if let detail = item.detail {
                                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            if item.selected {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(AsteriaTheme.accent)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .frame(minWidth: item.detail == nil ? 200 : 280, alignment: .leading)
                        .background(rowBackground(index: index, selected: item.selected), in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                        .opacity(item.enabled ? 1 : 0.35)
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
                }
            }
            .padding(6)
            .frame(minWidth: 224)
            .background(popSurface)
        }
    }

    private func rowBackground(index: Int, selected: Bool) -> Color {
        if index == highlightedIndex { return AsteriaTheme.surfaceFocused }
        if selected { return AsteriaTheme.accent.opacity(0.18) }
        return .clear
    }
}

private struct DeckCheckbox: View {
    @Binding var isOn: Bool
    /// Greyed out and non-interactive when the setting can't apply (e.g. MetalFX at native resolution).
    var enabled: Bool = true

    var body: some View {
        Button { if enabled { isOn.toggle() } } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn ? AsteriaTheme.accent : AsteriaTheme.pillTrack)
                    .frame(width: 28, height: 28)
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                } else {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.2)).frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct DeckKeycap: View {
    let text: String
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(text == "—" ? Color.secondary : Color.white)
                .padding(.horizontal, 14).frame(height: 34).frame(minWidth: 76)
                .background(popSurface, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

private extension CodecPreference {
    var deckName: String {
        switch self {
        case .auto: return "Auto"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        }
    }
}

private extension BitDepthPreference {
    var deckName: String { self == .eightBit ? "8-bit" : "10-bit" }
}

private extension AudioChannels {
    var deckName: String {
        switch self {
        case .stereo: return "Stereo"
        case .surround51: return "5.1 Surround"
        case .surround71: return "7.1 Surround"
        }
    }
}

private extension WindowMode {
    var deckName: String {
        switch self {
        case .windowedFullscreen: return "Windowed Fullscreen"
        case .windowed: return "Windowed"
        }
    }
}

enum CustomEntry: String, Identifiable {
    case resolution, frameRate, bitrate
    var id: String { rawValue }
}

/// Bit-rate is stored in Kbps but shown/edited in Mbps with up to one decimal (150, 150.5).
enum MbpsFormat {
    static func string(_ kbps: Int) -> String {
        let mbps = Double(kbps) / 1000
        return mbps == mbps.rounded() ? String(Int(mbps)) : String(format: "%.1f", mbps)
    }
}

/// Popup to type a custom resolution / frame rate / bit rate, instead of editing inline.
struct CustomEntrySheet: View {
    let entry: CustomEntry
    let store: SettingsEditor
    var onClose: () -> Void

    @State private var width: Int
    @State private var height: Int
    @State private var fps: Int
    @State private var mbps: Double

    init(entry: CustomEntry, store: SettingsEditor,
         onClose: @escaping () -> Void) {
        self.entry = entry
        self.store = store
        self.onClose = onClose
        var w = 1920, h = 1080
        if case let .custom(cw, ch) = store.draft.resolution { w = cw; h = ch }
        _width = State(initialValue: w)
        _height = State(initialValue: h)
        var f = 60
        if case let .fps(v) = store.draft.frameRate { f = v }
        _fps = State(initialValue: f)
        let kbps: Int
        if case let .manual(k) = store.draft.bitrate {
            kbps = k
        } else {
            kbps = store.recommendedBitrateKbps
        }
        _mbps = State(initialValue: Double(kbps) / 1000)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title3.bold())
            fields
            HStack {
                Spacer()
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    @ViewBuilder private var fields: some View {
        switch entry {
        case .resolution:
            HStack(spacing: 10) {
                labeledInt("Width", $width)
                Text("×").foregroundStyle(.secondary)
                labeledInt("Height", $height)
            }
        case .frameRate:
            labeledInt("Frames per second", $fps)
        case .bitrate:
            VStack(alignment: .leading, spacing: 6) {
                Text("Megabits per second").font(.caption).foregroundStyle(.secondary)
                TextField("", value: $mbps, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 120)
            }
        }
    }

    private var title: String {
        switch entry {
        case .resolution: return "Custom resolution"
        case .frameRate: return "Manual frame rate"
        case .bitrate: return "Manual bitrate"
        }
    }

    private func labeledInt(_ label: String, _ binding: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: binding, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 120)
        }
    }

    private func save() {
        switch entry {
        case .resolution:
            store.draft.resolution = VideoResolution.custom(clampingWidth: width, height: height)
        case .frameRate:
            store.draft.frameRate = FrameRate.fps(clamping: fps)
        case .bitrate:
            store.draft.bitrate = BitrateSetting.manual(clampingMbps: mbps)
        }
        onClose()
    }
}

/// Which action + chord kind the rebind popup is capturing.
struct RecordingTarget: Identifiable {
    let action: StreamAction
    let kind: ChordRecorder.Kind
    var id: String { "\(action.rawValue)-\(kind == .keyboard ? "kb" : "pad")" }
}

/// Popup that listens for the next key combination or controller combo and binds it to an action.
struct ChordRecorderSheet: View {
    let target: RecordingTarget
    let store: SettingsEditor
    var onClose: () -> Void

    @State private var recorder: ChordRecorder
    @State private var pulse = false

    init(target: RecordingTarget, input: SettingsEditor, onClose: @escaping () -> Void) {
        self.target = target
        self.store = input
        self.onClose = onClose
        _recorder = State(initialValue: ChordRecorder(kind: target.kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rebind: \(target.action.displayName)").font(.system(size: 20, weight: .bold))
                Text(prompt).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            // "Listening…" capture box — dashed crimson, pulsing dot, live captured combo.
            HStack(spacing: 14) {
                Circle().fill(AsteriaTheme.accent).frame(width: 12, height: 12).opacity(pulse ? 1 : 0.3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting…").font(.system(size: 17, weight: .semibold))
                    Text(target.kind == .keyboard ? "Press the keys simultaneously" : "Hold the buttons simultaneously")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(captured)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(captured == "…" ? Color.secondary : Color.white)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AsteriaTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 6])))
            if !conflicts.isEmpty {
                Text("Already used by " + conflicts.map(\.displayName).joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Button { onClose() } label: {
                    Text("Cancel").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(AsteriaTheme.pillTrack, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                if currentDisplay != "—" {
                    Text("Current: \(currentDisplay)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { save(); onClose() } label: {
                    Text("Save").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isEmpty ? Color.white.opacity(0.4) : Color.white)
                        .padding(.horizontal, 24).frame(height: 40)
                        .background(isEmpty ? AsteriaTheme.pillTrack : AsteriaTheme.accent, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(isEmpty)
            }
        }
        .padding(28).frame(width: 480)
        .background(Color(red: 0.067, green: 0.086, blue: 0.110))
        .onAppear {
            recorder.onCancel = onClose
            recorder.start()
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onDisappear { recorder.stop() }
    }

    private var currentDisplay: String {
        switch target.kind {
        case .keyboard: return store.keyChord(for: target.action).displayString
        case .gamepad: return store.gamepadChord(for: target.action).displayString
        }
    }

    private var prompt: String {
        target.kind == .keyboard
            ? "Press a key combination"
            : "Hold the buttons simultaneously, then release."
    }

    private var captured: String {
        switch target.kind {
        case .keyboard:
            if !recorder.keyChord.isEmpty { return recorder.keyChord.displayString }
            if !recorder.liveModifiers.glyphs.isEmpty { return recorder.liveModifiers.glyphs + "…" }
            return "…"
        case .gamepad:
            if !recorder.liveButtons.isEmpty {
                return GamepadChord(recorder.liveButtons).displayString
            }
            if !recorder.gamepadChord.isEmpty { return recorder.gamepadChord.displayString }
            return "…"
        }
    }

    private var isEmpty: Bool {
        target.kind == .keyboard ? recorder.keyChord.isEmpty : recorder.gamepadChord.isEmpty
    }

    private var conflicts: [StreamAction] {
        switch target.kind {
        case .keyboard:
            return recorder.keyChord.isEmpty
                ? []
                : store.keyboardConflicts(recorder.keyChord, for: target.action)
        case .gamepad:
            return recorder.gamepadChord.isEmpty
                ? []
                : store.gamepadConflicts(recorder.gamepadChord, for: target.action)
        }
    }

    private func save() {
        switch target.kind {
        case .keyboard: store.setKeyChord(recorder.keyChord, for: target.action)
        case .gamepad: store.setGamepadChord(recorder.gamepadChord, for: target.action)
        }
    }
}

/// About: app version + the bundled Third-Party Licenses, rendered readably (headers styled, license text mono).
struct AboutSettingsSection: View {
    private static let licenses: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Third-party license texts are bundled with the app."
        }
        return text
    }()

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "Version \(short)"
    }

    @State private var showWhatsNew = false
    @State private var versionHovering = false
    @State private var hasWhatsNew = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image("Icon").resizable().scaledToFit().frame(width: 64, height: 64)
                Text("Asteria").font(.title2.weight(.semibold))
                Button { showWhatsNew = true } label: {
                    Text(version).font(.caption)
                        .foregroundStyle(hasWhatsNew && versionHovering
                                         ? AnyShapeStyle(AsteriaTheme.accent)
                                         : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .disabled(!hasWhatsNew)
                .pointerStyle(hasWhatsNew ? .link : .default)
                .onHover { versionHovering = $0 }
                Text("A low-latency GameStream client for macOS.").font(.caption).foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showWhatsNew) { WhatsNewSheet() }
            .task { hasWhatsNew = await WhatsNew.currentChangelog() != nil }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)

            sectionHeader("Third-Party Licenses")
            ScrollView {
                LicenseText(markdown: Self.licenses)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 360)
            .background(AsteriaTheme.surface, in: .rect(cornerRadius: 10))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Divider().overlay(Color.white.opacity(0.07))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20).padding(.bottom, 8)
    }
}

/// Markdown render for the licenses doc: headings styled, prose gets inline bold/code, fenced
/// blocks stay verbatim monospaced. Fence markers and blockquote prefixes are hidden.
private struct LicenseText: View {
    let markdown: String

    private struct Row: Identifiable {
        let id: Int
        let kind: Kind
        enum Kind {
            case heading(AttributedString, size: CGFloat, weight: Font.Weight, topPad: CGFloat)
            case blockquote(AttributedString)
            case prose(AttributedString)
            case verbatim(String)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { row in
                switch row.kind {
                case let .heading(text, size, weight, topPad):
                    Text(text).font(.system(size: size, weight: weight)).foregroundStyle(.primary)
                        .padding(.top, topPad)
                case let .blockquote(text):
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                        .italic().padding(.leading, 8).textSelection(.enabled)
                case let .prose(text):
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                case let .verbatim(text):
                    Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var rows: [Row] {
        var result: [Row] = []
        var inFence = false
        for (offset, line) in markdown.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            let kind: Row.Kind = inFence ? .verbatim(line) : Self.proseKind(for: line)
            result.append(Row(id: offset, kind: kind))
        }
        return result
    }

    private static func proseKind(for line: String) -> Row.Kind {
        if line.hasPrefix("### ") {
            return .heading(inline(String(line.dropFirst(4))), size: 12, weight: .semibold, topPad: 6)
        } else if line.hasPrefix("## ") {
            return .heading(inline(String(line.dropFirst(3))), size: 13, weight: .semibold, topPad: 8)
        } else if line.hasPrefix("# ") {
            return .heading(inline(String(line.dropFirst(2))), size: 14, weight: .bold, topPad: 0)
        } else if line.hasPrefix("> ") {
            return .blockquote(inline(String(line.dropFirst(2))))
        }
        return .prose(inline(line))
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

@MainActor
private final class PlayStationLEDColorPicker: NSObject {
    private var onColorChange: ((NSColor) -> Void)?

    func present(color: NSColor, onColorChange: @escaping (NSColor) -> Void) {
        self.onColorChange = onColorChange
        let panel = NSColorPanel.shared
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        onColorChange?(panel.color)
    }
}

#if DEBUG
#Preview("Settings: global") {
    SettingsView(previewStore: .preview(scope: .global, capabilities: .unrestricted))
        .frame(width: 1080, height: 760)
}

#Preview("Settings: per-host (overriding)") {
    let host = HostRecord(id: "uid", name: "Living Room PC", address: "192.168.1.20", isPaired: true)
    var draft = StreamSettings.defaults
    draft.resolution = .uhd4K
    draft.frameRate = .fps(120)
    draft.bitrate = .manual(kbps: 80_000)
    return SettingsView(previewStore: .preview(scope: .host(host), draft: draft, customize: true,
                                               capabilities: .unrestricted))
        .frame(width: 1080, height: 760)
}

#Preview("Settings: Input") {
    SettingsView(previewStore: .preview(scope: .global, capabilities: .unrestricted), section: .input)
        .frame(width: 1080, height: 760)
}

#Preview("Settings: Appearance") {
    SettingsView(previewStore: .preview(scope: .global, capabilities: .unrestricted), section: .appearance)
        .frame(width: 1080, height: 760)
}
#endif
