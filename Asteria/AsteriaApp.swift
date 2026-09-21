import SwiftUI
import AsteriaKit

@main
struct AsteriaApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AsteriaAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(AsteriaTheme.accent)
        }
        .asteriaPlatformScene()
    }
}
