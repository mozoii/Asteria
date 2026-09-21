import SwiftUI
import QuartzCore
import UIKit
import AsteriaKit

/// SwiftUI wrapper hosting the renderer's `CALayer`, plus the iOS input-capture behavior.
struct StreamView: UIViewControllerRepresentable {
    let layer: CALayer
    let capture: StreamInputCapture

    /// A view controller, not a bare view: pointer lock is a view-controller property on iOS, and the
    /// stream needs one of its own rather than borrowing SwiftUI's hosting controller.
    func makeUIViewController(context: Context) -> StreamCaptureViewController {
        let controller = StreamCaptureViewController(hostedLayer: layer)
        controller.captureView.coordinator = capture
        capture.view = controller.captureView
        return controller
    }

    func updateUIViewController(_ controller: StreamCaptureViewController, context: Context) {
        controller.captureView.coordinator = capture
        capture.view = controller.captureView
    }
}

final class StreamCaptureViewController: UIViewController {
    let captureView: StreamCaptureView

    init(hostedLayer: CALayer) {
        captureView = StreamCaptureView(hostedLayer: hostedLayer)
        super.init(nibName: nil, bundle: nil)
        captureView.owner = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() { view = captureView }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = captureView.becomeFirstResponder()
        captureView.refreshPointerLock()
    }

    /// UIKit reads this whenever it re-evaluates lock; `refreshPointerLock` is what asks it to.
    override var prefersPointerLocked: Bool {
        captureView.coordinator?.wantsPointerLock ?? false
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
}

/// Hosts the renderer's Metal layer and captures hardware keyboard and pointer input.
///
/// GCKeyboard and GCMouse deliver the actual key and motion events off the main thread, exactly as on
/// macOS. This view's job is the part GameController can't do: own focus, swallow key presses so they
/// don't reach UIKit, and turn hover positions into absolute pointer updates for Desktop mode.
final class StreamCaptureView: UIView {
    weak var coordinator: StreamInputCapture?
    weak var owner: StreamCaptureViewController?
    private let hosted: CALayer

    init(hostedLayer: CALayer) {
        self.hosted = hostedLayer
        super.init(frame: .zero)
        backgroundColor = .black
        // A sublayer, not the backing layer: UIView owns its layer's geometry and would fight the
        // presenter over drawableSize. Aspect-fit inside the bounds paints the letterbox bars black.
        hosted.contentsGravity = .resizeAspect
        layer.addSublayer(hosted)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        hosted.contentsScale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        CATransaction.commit()
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Ask UIKit to re-read `prefersPointerLocked`; it only grants lock while the app is foreground,
    /// full-screen and key, so a refused request simply leaves the pointer visible.
    func refreshPointerLock() {
        owner?.setNeedsUpdateOfPrefersPointerLocked()
    }

    // MARK: - Keyboard

    /// Swallow hardware key presses while input is captured so they reach only the host. Released
    /// input falls through to UIKit, which is what lets ⌘-based app shortcuts work between streams.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard coordinator?.inputActive == true else {
            super.pressesBegan(presses, with: event)
            return
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard coordinator?.inputActive == true else {
            super.pressesEnded(presses, with: event)
            return
        }
    }

    // MARK: - Pointer

    /// Desktop mode wants absolute positions. A locked pointer reports no hover, so this only fires in
    /// Desktop mode, which is exactly when `shouldFeedAppKitPointer` is true.
    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard let coordinator, coordinator.shouldFeedAppKitPointer else { return }
        let point = recognizer.location(in: self)
        coordinator.inputSink?.feedAbsolutePointer(
            viewX: Int(point.x), viewY: Int(point.y),
            viewWidth: Int(bounds.width), viewHeight: Int(bounds.height),
            eventAgeNanos: 0)
    }
}
