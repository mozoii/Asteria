import UIKit
import AsteriaKit

/// What the local display can show. Feeds the capability probe (which resolutions and frame rates the
/// settings deck offers) and the present path's display-link rate range.
@MainActor
enum DisplayProbe {
    private static var screen: UIScreen { UIScreen.main }

    static var maximumRefreshHz: Int? {
        let refresh = screen.maximumFramesPerSecond
        return refresh > 0 ? refresh : nil
    }

    /// `nativeBounds` is always portrait-oriented, and a stream always plays landscape, so the longer
    /// edge is reported as the width. Without the swap a phone would offer 1179×2556 to the host.
    static var mainDisplayPixelSize: PixelSize? {
        let pixels = screen.nativeBounds.size
        let long = Int(max(pixels.width, pixels.height))
        let short = Int(min(pixels.width, pixels.height))
        guard long > 0, short > 0 else { return nil }
        return PixelSize(width: long, height: short)
    }

    static var mainDisplayRefreshHz: Int? { maximumRefreshHz }

    /// EDR headroom above 1 means the panel can drive highlights brighter than SDR white.
    static var mainDisplaySupportsEDR: Bool {
        screen.potentialEDRHeadroom > 1
    }
}
