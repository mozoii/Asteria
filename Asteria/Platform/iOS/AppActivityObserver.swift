import UIKit

/// Whether Asteria is the foreground app, and a callback when that changes. Drives "mute when
/// inactive" without the stream controller knowing what "active" means on this platform.
///
/// `willResignActive` covers the cases a player actually hits mid-stream — Control Centre, the
/// notification shade, an incoming call banner — which leave the app visible but not interactive.
@MainActor
final class AppActivityObserver {
    private var observers: [NSObjectProtocol] = []

    var isActive: Bool { UIApplication.shared.applicationState == .active }

    func start(onChange: @escaping @MainActor () -> Void) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [UIApplication.willResignActiveNotification,
                     UIApplication.didBecomeActiveNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in onChange() }
            }
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
