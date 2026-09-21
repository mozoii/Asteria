import AppKit
import AsteriaKit

/// What the local display can show. Feeds the capability probe (which resolutions and frame rates the
/// settings deck offers) and the present path's display-link rate range.
enum DisplayProbe {
    /// Fastest panel attached, not the one that happens to have focus: a stream can be dragged to a
    /// 240 Hz display after it starts, and the link clamps to whichever display actually hosts it.
    static var maximumRefreshHz: Int? {
        NSScreen.screens.map(\.maximumFramesPerSecond).max()
    }

    /// Native pixel size of the main display, used for "Match display" and the MetalFX upscale target.
    static var mainDisplayPixelSize: PixelSize? {
        guard let screen = NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor
        return PixelSize(width: Int(screen.frame.width * scale),
                         height: Int(screen.frame.height * scale))
    }

    static var mainDisplayRefreshHz: Int? {
        guard let screen = NSScreen.main else { return nil }
        let refresh = screen.maximumFramesPerSecond
        return refresh > 0 ? refresh : nil
    }

    /// The stream window can move to a bigger or faster display after it starts, so the full
    /// ladders stay.
    static let limitsPresetsToPanel = false

    static var mainDisplaySupportsEDR: Bool {
        (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }
}
