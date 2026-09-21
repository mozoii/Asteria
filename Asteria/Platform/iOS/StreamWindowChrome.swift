import SwiftUI
import UIKit
import AsteriaKit

/// How iOS frames a live stream: full-bleed and landscape, with the home indicator and status bar out
/// of the way and edge swipes deferred so a flick near the bezel doesn't drop the player out of a game.
///
/// Backgrounding ends the session rather than trying to survive it. iOS suspends the process within
/// seconds, which kills the UDP and ENet sockets and makes touching Metal a termination offence, so a
/// "kept" session would come back dead. Ending cleanly leaves the game running on the host, and
/// returning to the foreground resumes into it — the same path the reconnect button takes.
private struct StreamWindowChrome: ViewModifier {
    let controller: StreamController
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var suspendedInBackground = false

    func body(content: Content) -> some View {
        content
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .defersSystemGestures(on: .all)
            .onAppear {
                AsteriaAppDelegate.streamIsLive = true
                requestOrientationUpdate()
                // iOS streams always fill the screen, so there is no windowed mode to toggle into.
                controller.onToggleFullscreen = {}
            }
            .onDisappear {
                AsteriaAppDelegate.streamIsLive = false
                requestOrientationUpdate()
                if !isRunningInPreview { Task { await controller.disconnect() } }
            }
            .onChange(of: controller.phase) { _, phase in
                if phase == .ended { onClose() }
            }
            .onChange(of: scenePhase) { _, phase in
                guard !isRunningInPreview else { return }
                switch phase {
                case .background:
                    guard controller.phase == .streaming else { return }
                    suspendedInBackground = true
                    Task { await controller.disconnect() }
                case .active:
                    guard suspendedInBackground else { return }
                    suspendedInBackground = false
                    controller.reconnect()
                default:
                    break
                }
            }
    }

    /// Ask UIKit to re-read the delegate's orientation mask now that the stream's state changed.
    private func requestOrientationUpdate() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: AsteriaAppDelegate.streamIsLive
                                         ? .landscape : .all))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

extension View {
    func streamWindowChrome(controller: StreamController,
                            onClose: @escaping () -> Void) -> some View {
        modifier(StreamWindowChrome(controller: controller, onClose: onClose))
    }

    /// The device decides the size; a minimum would only push content off a phone screen.
    func shellMinimumSize() -> some View { self }
}
