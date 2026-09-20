import AppKit

/// Whether Asteria is the frontmost app, and a callback when that changes. Drives "mute when
/// inactive" without the stream controller knowing what "active" means on this platform.
@MainActor
final class AppActivityObserver {
    private var observers: [NSObjectProtocol] = []

    var isActive: Bool { NSApp.isActive }

    func start(onChange: @escaping @MainActor () -> Void) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [NSApplication.didResignActiveNotification,
                     NSApplication.didBecomeActiveNotification].map { name in
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
