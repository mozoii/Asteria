@preconcurrency import GameController
import Combine
import SwiftUI
import AsteriaKit

/// One frame (d-pad, face buttons, shoulders, stick); Sendable to hop from handler thread to main actor.
private struct PadSnapshot: Sendable {
    var up = false, down = false, left = false, right = false
    var a = false, b = false, btnX = false, btnY = false, lb = false, rb = false
    var stickX: Float = 0, stickY: Float = 0

    init() {}
    init(_ gp: GCExtendedGamepad) {
        up = gp.dpad.up.isPressed
        down = gp.dpad.down.isPressed
        left = gp.dpad.left.isPressed
        right = gp.dpad.right.isPressed
        a = gp.buttonA.isPressed
        b = gp.buttonB.isPressed
        btnX = gp.buttonX.isPressed
        btnY = gp.buttonY.isPressed
        lb = gp.leftShoulder.isPressed
        rb = gp.rightShoulder.isPressed
        stickX = gp.leftThumbstick.xAxis.value
        stickY = gp.leftThumbstick.yAxis.value
    }
}

/// Surfaces a gamepad's directional menu intents for a plain `@State` highlight — macOS has no focus engine for custom views.
@MainActor
final class ControllerNavReader: ObservableObject {
    enum Dir { case up, down, left, right, activate, back, options, reset, prevSection, nextSection }
    @Published private(set) var tick = 0
    @Published private(set) var isConnected = false
    private var pending: [Dir] = []
    private var controller: GCController?
    private var connectObs: NSObjectProtocol?
    private var disconnectObs: NSObjectProtocol?
    private var prev = PadSnapshot()
    private var stickLatched = false

    func start() {
        attachFirstAvailable()
        connectObs = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.attachFirstAvailable() }
        }
        disconnectObs = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let cur = self.controller, !GCController.controllers().contains(where: { $0 === cur }) {
                    self.controller = nil
                    self.isConnected = false
                }
                self.attachFirstAvailable()
            }
        }
    }

    func stop() {
        // Do NOT nil the gamepad handler: screens share one `valueChangedHandler` slot and SwiftUI fires the
        // incoming screen's install() BEFORE this onDisappear, so nilling would wipe its fresh handler.
        controller = nil
        isConnected = false
        if let o = connectObs { NotificationCenter.default.removeObserver(o) }
        if let o = disconnectObs { NotificationCenter.default.removeObserver(o) }
        connectObs = nil
        disconnectObs = nil
    }

    /// Re-install our handler on the current pad — call after a rebind sheet (ChordRecorder nils it).
    func rearm() { install() }

    func dequeue() -> Dir? { pending.isEmpty ? nil : pending.removeFirst() }
    func flush() { pending.removeAll() }

    /// Drain queued inputs through `handle`; when `blocked`, discard them instead.
    func drain(blocked: Bool, _ handle: (Dir) -> Void) {
        if blocked { flush(); return }
        while let dir = dequeue() { handle(dir) }
    }

    private func attachFirstAvailable() {
        guard controller == nil, let c = GCController.controllers().first, c.extendedGamepad != nil else { return }
        controller = c
        isConnected = true
        prev = PadSnapshot()
        stickLatched = false
        install()
    }

    private func install() {
        guard let gp = controller?.extendedGamepad else { return }
        gp.valueChangedHandler = { [weak self] gp, _ in
            let snap = PadSnapshot(gp)                       // snapshot off the handler thread, then hop to main
            Task { @MainActor in self?.ingest(snap) }
        }
    }

    private func ingest(_ s: PadSnapshot) {
        edge(s.up, prev.up, .up)
        edge(s.down, prev.down, .down)
        edge(s.left, prev.left, .left)
        edge(s.right, prev.right, .right)
        edge(s.a, prev.a, .activate)
        edge(s.b, prev.b, .back)
        edge(s.btnX, prev.btnX, .options)
        edge(s.btnY, prev.btnY, .reset)
        edge(s.lb, prev.lb, .prevSection)
        edge(s.rb, prev.rb, .nextSection)
        prev = s

        // Left stick acts as a d-pad, latched so one deflection is one step; dominant axis wins.
        if abs(s.stickX) < 0.3 && abs(s.stickY) < 0.3 {
            stickLatched = false
        } else if !stickLatched {
            let t: Float = 0.6
            if abs(s.stickY) >= abs(s.stickX) {
                if s.stickY > t { stickLatched = true; emit(.up) }
                else if s.stickY < -t { stickLatched = true; emit(.down) }
            } else {
                if s.stickX < -t { stickLatched = true; emit(.left) }
                else if s.stickX > t { stickLatched = true; emit(.right) }
            }
        }
    }

    private func edge(_ now: Bool, _ was: Bool, _ dir: Dir) {
        if now && !was { emit(dir) }
    }

    private func emit(_ dir: Dir) {
        pending.append(dir)
        tick &+= 1
    }
}

extension ControllerNavReader.Dir {
    /// Cursor movement only; activation/back/options don't move the highlight.
    var deckDirection: DeckDir? {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        default: nil
        }
    }
}

extension View {
    /// Wires a screen's nav lifecycle and mirrors the d-pad to the keyboard (arrows move, Return activates).
    func controllerNavigation(_ nav: ControllerNavReader,
                              focusFirst: @escaping () -> Void,
                              drain: @escaping () -> Void,
                              move: @escaping (ControllerNavReader.Dir) -> Void) -> some View {
        self
            .onAppear { nav.start(); focusFirst() }
            .onDisappear { nav.stop() }
            .onChange(of: nav.tick) { _, _ in drain() }
            .onChange(of: nav.isConnected) { _, connected in if connected { focusFirst() } }
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: move(.up)
                case .down: move(.down)
                case .left: move(.left)
                case .right: move(.right)
                @unknown default: break
                }
            }
            .onKeyPress(.return) { move(.activate); return .handled }
    }
}
