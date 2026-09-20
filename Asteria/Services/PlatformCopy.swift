#if os(iOS)
import UIKit
#endif

/// Nouns and hints that name the device the app is running on. The Mac build says "Mac"; the iOS
/// build says "iPhone" or "iPad". Keeping them here means shared screens read naturally on both
/// rather than calling an iPad a Mac.
enum PlatformCopy {
    #if os(macOS)
    /// What to call this machine in running prose ("Stream your PC to this Mac.").
    static let deviceNoun = "Mac"
    /// Where the library document lives, for the load-failure message.
    static let libraryPathHint = "~/Library/Application Support/Asteria/library.json"
    /// Whether this platform can present a stream in a resizable window.
    static let supportsWindowedStreams = true
    /// "Match Mac" reads better beside the PC resolutions in the picker; iOS has no such pairing.
    static let matchDisplayLabel = "Match Mac"
    static let osName = "macOS"
    /// Pointer mode, button swaps and keyboard shortcuts are worth a settings section here.
    static let supportsKeyboardAndMouseSettings = true
    static let inputSettingsSubtitle = "Mouse, keyboard and controller behavior, plus shortcuts"
    /// macOS can show another app beside the stream, so "another app is active" is the trigger.
    static let muteWhenInactiveDetail = "Mute stream audio while another app is active."
    #else
    @MainActor
    static var deviceNoun: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
    /// The container is private to the app, so there is no user-visible path to point at.
    static let libraryPathHint = "Asteria's saved data"
    static let supportsWindowedStreams = false
    static let matchDisplayLabel = "Match display"
    static let osName = "iOS"
    /// Touch and controllers are the input story on a phone or tablet: no pointer mode to pick
    /// (every input drives the game pointer) and no keyboard shortcuts to rebind.
    static let supportsKeyboardAndMouseSettings = false
    static let inputSettingsSubtitle = "Controller behavior and shortcuts"
    /// iOS streams own the screen, so the trigger is the app losing focus, not another app gaining it.
    static let muteWhenInactiveDetail = "Mute stream audio while Asteria isn't in the foreground."
    #endif
}
