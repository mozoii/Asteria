import UIKit
import AsteriaKit

/// App-side input policy owner.
/// Routes engine requests to pointer side-effects and view requests to the engine.
///
/// The Mac hides the cursor and dissociates it from the mouse; iOS asks UIKit for pointer lock, which
/// does both at once — it hides the pointer and delivers raw deltas to GCMouse instead of moving a
/// system cursor. Lock needs the app to own the full screen (`UIRequiresFullScreen`), and UIKit only
/// grants it while the view controller says it wants it, so the request is a state the container
/// re-reads rather than a one-shot call.
@MainActor
final class StreamInputCapture: ObservableObject {
    /// True while stream input is active; observed by the stream view to show the recapture hint.
    @Published private(set) var inputActive = true

    /// Requested by view focus/taps; forwarded to `StreamSession.setInputCapture`.
    var onInputStateRequest: ((Bool) -> Void)?

    /// Keyboard/mouse sink (set once streaming starts); the capture view and touch overlay feed it.
    var inputSink: LocalInputSink?

    weak var view: StreamCaptureView?

    private var currentMouseMode: MouseMode = .game

    /// Game mode is fed by GCMouse deltas; touch and hover positions are only for Desktop mode.
    var shouldFeedAppKitPointer: Bool {
        MouseRoute.shouldForwardAppKitPointer(inputActive: inputActive,
                                              absoluteMode: currentMouseMode.usesAbsolutePointer)
    }

    /// Pointer lock is wanted while input is captured in Game mode. Desktop mode wants the pointer
    /// visible and absolute, which is exactly what an unlocked pointer already gives.
    var wantsPointerLock: Bool { inputActive && !currentMouseMode.usesAbsolutePointer }

    lazy var surface: StreamSurface = CaptureSurfaceBridge(coordinator: self)

    /// Apply pointer side-effects of an input-state change. Idempotent for engine and app requests.
    func applyInputState(active: Bool, mouseMode: MouseMode) {
        currentMouseMode = mouseMode
        inputActive = active
        view?.refreshPointerLock()
    }

    /// Request an input-state change from the view.
    func requestInputState(active: Bool) {
        applyInputState(active: active, mouseMode: currentMouseMode)
        onInputStateRequest?(active)
    }

    /// Teardown: release the pointer unconditionally (idempotent with the engine's surface release).
    func restoreCursor() {
        inputActive = false
        view?.refreshPointerLock()
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
