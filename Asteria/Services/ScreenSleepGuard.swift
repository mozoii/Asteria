import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.pwr_mgt

/// Holds a display idle-sleep prevention assertion while a stream is live.
/// A gamepad-only session generates no local HID activity, so without this the
/// Mac treats the user as idle and blanks the screen mid-stream.
@MainActor
struct ScreenSleepGuard {
    private var assertionID: IOPMAssertionID?

    mutating func start() {
        guard assertionID == nil else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Asteria streaming session" as CFString,
            &id)
        if result == kIOReturnSuccess {
            assertionID = id
        }
    }

    mutating func end() {
        guard let id = assertionID else { return }
        assertionID = nil
        IOPMAssertionRelease(id)
    }
}
