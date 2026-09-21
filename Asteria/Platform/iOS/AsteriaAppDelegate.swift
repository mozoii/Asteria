import UIKit
import SwiftUI

/// Orientation policy for the whole app. The shell rotates freely; a live stream is landscape-only,
/// because the host renders a landscape mode and a portrait letterbox would waste most of the panel.
/// `StreamWindowChrome` flips `streamIsLive` around the stream's lifetime.
final class AsteriaAppDelegate: NSObject, UIApplicationDelegate {
    /// Read by UIKit on the main thread whenever it re-evaluates supported orientations.
    @MainActor static var streamIsLive = false

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated {
            guard Self.streamIsLive else {
                return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
            }
            return .landscape
        }
    }
}

extension Scene {
    /// iOS has no window chrome or app menu to configure; the Mac build adds both here.
    func asteriaPlatformScene() -> some Scene { self }
}
