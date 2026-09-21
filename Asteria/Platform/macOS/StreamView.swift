import SwiftUI
import QuartzCore
import AsteriaKit

/// SwiftUI wrapper hosting renderer's `CALayer`; thin window glue plus AppKit input-capture behavior.
struct StreamView: NSViewRepresentable {
    let layer: CALayer
    let capture: StreamInputCapture

    func makeNSView(context: Context) -> StreamCaptureView {
        let view = StreamCaptureView(hostedLayer: layer)
        view.coordinator = capture
        capture.view = view
        return view
    }

    func updateNSView(_ nsView: StreamCaptureView, context: Context) {
        nsView.coordinator = capture
        capture.view = nsView
    }
}

/// Hosts the renderer's Metal layer as its backing layer (not a sublayer) so a fullscreen opaque surface can be promoted
/// to a direct scanout plane. As first responder it captures keyboard/mouse via NSEvent and feeds the engine.
final class StreamCaptureView: NSView {
    weak var coordinator: StreamInputCapture?
    private let hosted: CALayer
    /// Modifier keys arrive only as flag changes; track which are down to derive press/release edges.
    private var heldModifiers: Set<UInt16> = []

    init(hostedLayer: CALayer) {
        self.hosted = hostedLayer
        super.init(frame: .zero)
        wantsLayer = true   // triggers makeBackingLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Background paints the letterbox bars (the drawable is aspect-fit within bounds via `contentsGravity`).
    override func makeBackingLayer() -> CALayer {
        hosted.backgroundColor = NSColor.black.cgColor
        return hosted
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The click that re-focuses the window must also reach the view, or the first click can't recapture input.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NSEvent.isMouseCoalescingEnabled = false   // deliver raw per-report deltas, like a native game
        window.acceptsMouseMovedEvents = true
        claimFocus(window)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowDidResignKey),
                       name: NSWindow.didResignKeyNotification, object: window)
        nc.addObserver(self, selector: #selector(windowDidBecomeKey),
                       name: NSWindow.didBecomeKeyNotification, object: window)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Reclaim first responder after SwiftUI's responder setup without reactivating stream input.
    private func claimFocus(_ window: NSWindow) {
        window.makeFirstResponder(self)
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self { window.makeFirstResponder(self) }
        }
    }

    /// Lost key focus: release capture and drop modifier state so a key held across the switch can't strand down.
    @objc private func windowDidResignKey() {
        heldModifiers.removeAll()
        coordinator?.requestInputState(active: false)
    }

    /// Regained key focus (e.g. entering full screen / ⌘-Tab back): reclaim the responder.
    @objc private func windowDidBecomeKey() {
        guard let window else { return }
        claimFocus(window)
    }

    override func keyDown(with event: NSEvent) { feedKey(event, pressed: true) }
    override func keyUp(with event: NSEvent) { feedKey(event, pressed: false) }

    override func flagsChanged(with event: NSEvent) {
        guard let usage = HIDKeycodeMap.hidUsage(forVirtualKey: event.keyCode) else { return }
        let pressed = !heldModifiers.contains(event.keyCode)
        if pressed { heldModifiers.insert(event.keyCode) } else { heldModifiers.remove(event.keyCode) }
        coordinator?.inputSink?.feedKey(scancode: usage, pressed: pressed)
    }

    private func feedKey(_ event: NSEvent, pressed: Bool) {
        guard let usage = HIDKeycodeMap.hidUsage(forVirtualKey: event.keyCode) else { return }
        coordinator?.inputSink?.feedKey(scancode: usage, pressed: pressed)
    }

    /// Modified keys (e.g. Ctrl+G) reach the responder chain only via key-equivalents; while captured, feed them to
    /// the host and consume so local menu items don't fire. While released, let app shortcuts through.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard coordinator?.inputActive == true else {
            return super.performKeyEquivalent(with: event)
        }
        feedKey(event, pressed: true)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // First click while inactive recaptures; active input forwards clicks to the host.
        if coordinator?.inputActive == true {
            coordinator?.inputSink?.feedMouseButton(.left, down: true)
        } else {
            coordinator?.requestInputState(active: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if coordinator?.inputActive == true {
            coordinator?.inputSink?.feedMouseButton(.left, down: false)
        }
    }

    override func rightMouseDown(with event: NSEvent) { feedButton(.right, down: true) }
    override func rightMouseUp(with event: NSEvent) { feedButton(.right, down: false) }
    override func otherMouseDown(with event: NSEvent) { feedOtherButton(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { feedOtherButton(event, down: false) }

    override func mouseMoved(with event: NSEvent) { feedMotion(event) }
    override func mouseDragged(with event: NSEvent) { feedMotion(event) }
    override func rightMouseDragged(with event: NSEvent) { feedMotion(event) }
    override func otherMouseDragged(with event: NSEvent) { feedMotion(event) }

    override func scrollWheel(with event: NSEvent) {
        guard coordinator?.inputActive == true else { return }
        coordinator?.inputSink?.feedScroll(preciseX: event.scrollingDeltaX, preciseY: event.scrollingDeltaY)
    }

    private func feedButton(_ button: LocalMouseButton, down: Bool) {
        guard coordinator?.inputActive == true else { return }
        coordinator?.inputSink?.feedMouseButton(button, down: down)
    }

    private func feedOtherButton(_ event: NSEvent, down: Bool) {
        let button: LocalMouseButton
        switch event.buttonNumber {
        case 2: button = .middle
        case 3: button = .extra1
        case 4: button = .extra2
        default: return
        }
        feedButton(button, down: down)
    }

    private func feedMotion(_ event: NSEvent) {
        guard let coordinator, coordinator.shouldFeedAppKitPointer else { return }
        let eventAgeNanos = motionEventAgeNanos(event)
        let point = convert(event.locationInWindow, from: nil)
        coordinator.inputSink?.feedAbsolutePointer(
            viewX: Int(point.x), viewY: Int(point.y),
            viewWidth: Int(bounds.width), viewHeight: Int(bounds.height),
            eventAgeNanos: eventAgeNanos
        )
    }

    private func motionEventAgeNanos(_ event: NSEvent) -> UInt64 {
        let seconds = ProcessInfo.processInfo.systemUptime - event.timestamp
        return UInt64(max(0, seconds * 1_000_000_000))
    }
}

/// Hands the hosting `NSWindow` back to SwiftUI so the stream container can drive native full screen.
struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ResolverView(onResolve: onResolve) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Reports the window when the view attaches; a deferred `Task` read can miss it and resolve nil on fast reconnect.
    final class ResolverView: NSView {
        private let onResolve: (NSWindow?) -> Void
        init(onResolve: @escaping (NSWindow?) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve(window)
        }
    }
}
