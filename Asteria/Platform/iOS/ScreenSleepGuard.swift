import UIKit

/// Keeps the screen awake while a stream is live. A gamepad-only session generates no touches, so
/// without this iOS treats the user as idle and dims, then locks, mid-stream.
@MainActor
struct ScreenSleepGuard {
    private var held = false

    mutating func start() {
        guard !held else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        held = true
    }

    mutating func end() {
        guard held else { return }
        held = false
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
