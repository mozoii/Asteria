import AppKit
import AsteriaKit

/// App-side input policy owner.
/// Routes engine requests to cursor side-effects and view requests to the engine.
/// Active input hides the cursor; Game mode also decouples it.
@MainActor
final class StreamInputCapture: ObservableObject {
    /// True while stream input is active; observed by the stream view to show the recapture hint.
    @Published private(set) var inputActive = true

    /// Requested by view focus/clicks; forwarded to `StreamSession.setInputCapture`.
    var onInputStateRequest: ((Bool) -> Void)?

    /// NSEvent keyboard/mouse sink (set once streaming starts); the capture view feeds it directly.
    var inputSink: LocalInputSink?

    weak var view: StreamCaptureView?

    private var cursorHidden = false
    private var currentMouseMode: MouseMode = .game

    /// Game mode is fed by GCMouse; AppKit positions are only for Desktop mode.
    var shouldFeedAppKitPointer: Bool {
        MouseRoute.shouldForwardAppKitPointer(inputActive: inputActive,
                                              absoluteMode: currentMouseMode.usesAbsolutePointer)
    }

    lazy var surface: StreamSurface = CaptureSurfaceBridge(coordinator: self)

    /// Apply cursor side-effects of an input-state change. Idempotent for engine and app requests.
    func applyInputState(active: Bool, mouseMode: MouseMode) {
        currentMouseMode = mouseMode
        inputActive = active
        NSEvent.isMouseCoalescingEnabled = mouseMode == .desktop
        if active {
            CGAssociateMouseAndMouseCursorPosition(mouseMode == .game ? 0 : 1)
            if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        }
    }

    /// Request an input-state change from the view.
    func requestInputState(active: Bool) {
        applyInputState(active: active, mouseMode: currentMouseMode)
        onInputStateRequest?(active)
    }

    /// Teardown: unconditionally restore cursor (idempotent with engine's surface release).
    func restoreCursor() {
        CGAssociateMouseAndMouseCursorPosition(1)
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        inputActive = false
    }
}

private final class CaptureSurfaceBridge: StreamSurface, @unchecked Sendable {
    private weak var coordinator: StreamInputCapture?
    init(coordinator: StreamInputCapture) { self.coordinator = coordinator }
    func applyInputState(active: Bool, mouseMode: MouseMode) {
        if Thread.isMainThread {
            applyOnMain(active: active, mouseMode: mouseMode)
        } else {
            // Async, not sync: a sync hop to main from the off-main input-stop path risks lock inversion.
            // Surface state is idempotent and session-side ordering is serialized by StreamController.captureTask.
            DispatchQueue.main.async { [self] in
                applyOnMain(active: active, mouseMode: mouseMode)
            }
        }
    }

    private func applyOnMain(active: Bool, mouseMode: MouseMode) {
        MainActor.assumeIsolated { [weak coordinator] in
            coordinator?.applyInputState(active: active, mouseMode: mouseMode)
        }
    }
}
