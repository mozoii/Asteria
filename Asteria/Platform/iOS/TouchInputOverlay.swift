import SwiftUI
import UIKit
import QuartzCore
import AsteriaKit

/// Touch as a trackpad, plus a floating button that reaches the overlay menu.
///
/// Without this an iPhone with no accessories could start a stream and then never leave it: the menu
/// is otherwise only reachable by a keyboard chord or a controller combo. Classification lives in
/// `TouchPointerModel`; this view only reports touches and forwards the resulting commands.
private struct TouchInputOverlay: ViewModifier {
    let controller: StreamController

    func body(content: Content) -> some View {
        content
            .overlay { TouchPointerSurface(controller: controller).allowsHitTesting(true) }
            .overlay(alignment: .topLeading) { menuButton }
    }

    /// Always reachable, and deliberately small and dim: it sits over a game, not over a document.
    private var menuButton: some View {
        Button { controller.toggleMenu() } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: .circle)
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .padding(.leading, 18)
        .padding(.top, 18)
        .opacity(controller.showMenu ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: controller.showMenu)
        .accessibilityLabel("Stream menu")
    }
}

private struct TouchPointerSurface: UIViewRepresentable {
    let controller: StreamController

    func makeUIView(context: Context) -> TouchPointerView {
        let view = TouchPointerView()
        view.controller = controller
        return view
    }

    func updateUIView(_ uiView: TouchPointerView, context: Context) {
        uiView.controller = controller
    }
}

/// Reports raw touches to the model. Raw `UITouch` rather than gesture recognizers: the recognizer
/// set needed here (tap, two- and three-finger tap, long press, one- and two-finger pan) spends most
/// of its time failing against each other, which shows up as a delay before the pointer moves.
final class TouchPointerView: UIView {
    var controller: StreamController?

    private var model = TouchPointerModel()
    /// Every touch the view is currently tracking, with the stable id the model identifies it by.
    /// Held so a snapshot can read all live positions, not just the ones in the event that woke us.
    private var tracked: [(touch: UITouch, id: Int)] = []
    private var nextID = 0
    /// Drives the long-press deadline while fingers stay still, which produces no touch events.
    private var holdTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The overlay covers the video, so it must not swallow taps meant for the menu button or the
    /// in-stream menu; only hits on bare video belong to the trackpad.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? (controller?.showMenu == true ? nil : self) : hit
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where !tracked.contains(where: { $0.touch === touch }) {
            tracked.append((touch, nextID))
            nextID &+= 1
        }
        syncPointerMode()
        deliver(model.update(touches: snapshot(), at: CACurrentMediaTime()))
        startHoldTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(model.update(touches: snapshot(), at: CACurrentMediaTime()))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        forget(touches)
        deliver(model.update(touches: snapshot(), at: CACurrentMediaTime()))
        if tracked.isEmpty { stopHoldTimer() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        forget(touches)
        if tracked.isEmpty {
            deliver(model.cancel())
            stopHoldTimer()
        } else {
            deliver(model.update(touches: snapshot(), at: CACurrentMediaTime()))
        }
    }

    private func forget(_ touches: Set<UITouch>) {
        tracked.removeAll { entry in touches.contains(where: { $0 === entry.touch }) }
    }

    private func snapshot() -> [TouchPoint] {
        tracked.map { entry in
            let point = entry.touch.location(in: self)
            return TouchPoint(id: entry.id, x: Double(point.x), y: Double(point.y))
        }
    }

    /// Desktop mode drives an absolute pointer, and the mode can be flipped mid-stream from the menu.
    private func syncPointerMode() {
        model.usesAbsolutePointer = controller?.mouseMode.usesAbsolutePointer ?? false
    }

    private func startHoldTimer() {
        guard holdTimer == nil else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deliver(self.model.tick(at: CACurrentMediaTime()))
            }
        }
    }

    private func stopHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func deliver(_ commands: [TouchCommand]) {
        guard let controller, !commands.isEmpty else { return }
        let sink = controller.inputCapture.inputSink
        for command in commands {
            switch command {
            case let .moveRelative(dx, dy):
                sink?.feedRelativePointer(deltaX: dx, deltaY: dy)
            case let .moveAbsolute(x, y):
                sink?.feedAbsolutePointer(viewX: Int(x), viewY: Int(y),
                                          viewWidth: Int(bounds.width), viewHeight: Int(bounds.height),
                                          eventAgeNanos: 0)
            case let .leftButton(down):
                sink?.feedMouseButton(.left, down: down)
            case let .rightButton(down):
                sink?.feedMouseButton(.right, down: down)
            case let .scroll(dx, dy):
                sink?.feedScroll(preciseX: dx, preciseY: dy)
            case .openMenu:
                controller.toggleMenu()
            }
        }
    }
}

extension View {
    func streamTouchControls(controller: StreamController) -> some View {
        modifier(TouchInputOverlay(controller: controller))
    }
}
