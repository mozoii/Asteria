import SwiftUI
import AppKit
import AsteriaKit

/// A menu item's key equivalent, saved so it can be restored after immersive full screen suppresses it.
private struct SavedShortcut {
    let item: NSMenuItem
    let key: String
    let mods: NSEvent.ModifierFlags
}

private final class StreamContainerPresence {
    var generation = 0
}

/// How macOS frames a live stream: immersive full screen, windowed sizing, title-bar visibility, and
/// the destructive menu shortcuts that must not fire while playing. Owns the exit path too, so the
/// window is unwound before the library comes back.
private struct StreamWindowChrome: ViewModifier {
    let controller: StreamController
    let onClose: () -> Void

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

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { newWindow in
                window = newWindow
                if let newWindow, controller.phase == .streaming {
                    scheduleWindowedTitleBarSetting(for: newWindow)
                }
                // Window can resolve after .streaming on a reconnect, so re-attempt here or the entry is lost.
                if let newWindow { enterFullscreenIfStreaming(newWindow) }
            })
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
}

extension View {
    func streamWindowChrome(controller: StreamController,
                            onClose: @escaping () -> Void) -> some View {
        modifier(StreamWindowChrome(controller: controller, onClose: onClose))
    }

    /// Touch controls are iOS-only; a Mac has a pointer and a keyboard.
    func streamTouchControls(controller: StreamController) -> some View { self }

    /// Keeps the Mac window from being resized smaller than the shell's two-column layout needs.
    func shellMinimumSize() -> some View { frame(minWidth: 880, minHeight: 600) }
}
