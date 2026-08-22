import Foundation
@preconcurrency import GameController
import GameStreamProtocol
import AsteriaModel

public extension GCController {
    var isPlayStationController: Bool {
        if extendedGamepad is GCDualSenseGamepad || extendedGamepad is GCDualShockGamepad {
            return true
        }
        return productCategory.contains("DualSense") || productCategory.contains("DualShock")
    }
}

/// Running tally of host→client control messages handled, by kind.
public struct InboundControlCounts: Sendable, Equatable, CustomStringConvertible {
    public var rumble = 0, rumbleTriggers = 0, led = 0, adaptiveTriggers = 0
    public var motion = 0, hdr = 0, termination = 0, unknown = 0
    public init() {}
    public var total: Int { rumble + rumbleTriggers + led + adaptiveTriggers + motion + hdr + termination + unknown }
    public var description: String {
        "rumble:\(rumble) triggers:\(rumbleTriggers) led:\(led) adaptive:\(adaptiveTriggers) "
            + "motion:\(motion) hdr:\(hdr) term:\(termination) other:\(unknown) (total:\(total))"
    }
}

/// Carries a GameController object across a queue hop.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Mouse delivery routing: absolute (desktop) or relative (game).
public enum MouseRoute: Sendable {
    case absolute
    case relative
}

public final class InputEngine: @unchecked Sendable, DeviceActuator, LocalInputSink {
    private let sender: InputSender
    private let core: InputCore
    private let queue = DispatchQueue(label: "io.github.mozoii.asteria.input", qos: .userInteractive)

    private var slots = [GCController?](repeating: nil, count: 16)
    private var haptics = [SlotHaptics?](repeating: nil, count: 16)
    private var ledSmoothers = [LEDSmoother](repeating: LEDSmoother(), count: 16)
    private var observers: [NSObjectProtocol] = []
    private var rumbleWatchdogTimer: DispatchSourceTimer?
    private var usesAbsolutePointer: Bool
    private let playStationLEDColor: PlayStationLEDColor

    public var inboundCounts: InboundControlCounts { core.inboundCounts }

    private let commandsContinuation: AsyncStream<StreamAction>.Continuation
    public let commands: AsyncStream<StreamAction>

    private let menuNavContinuation: AsyncStream<MenuNav>.Continuation
    public let menuEvents: AsyncStream<MenuNav>

    private let terminationsContinuation: AsyncStream<UInt32>.Continuation
    public let terminations: AsyncStream<UInt32>

    public init(transport: any InputTransport, keybindings: Keybindings = .defaults,
                mouseMode: MouseMode = .game, swapFaceButtons: Bool = false,
                swapMouseButtons: Bool = false, swapWinAltKeys: Bool = false,
                playStationEmulation: PlayStationControllerEmulation = .playStation4,
                playStationLEDColor: PlayStationLEDColor = .blue,
                systemKeyCaptureActive: Bool = false, streamWidth: Int = 0, streamHeight: Int = 0,
                surface: StreamSurface? = nil, tickHz: UInt64 = 250) {
        let sender = InputSender(transport: transport, tickHz: tickHz)
        let (commands, continuation) = AsyncStream<StreamAction>.makeStream()
        let (menuEvents, menuContinuation) = AsyncStream<MenuNav>.makeStream()
        let (terminations, terminationsContinuation) = AsyncStream<UInt32>.makeStream()
        self.sender = sender
        self.commands = commands
        self.commandsContinuation = continuation
        self.menuEvents = menuEvents
        self.menuNavContinuation = menuContinuation
        self.terminations = terminations
        self.terminationsContinuation = terminationsContinuation
        self.usesAbsolutePointer = mouseMode.usesAbsolutePointer
        self.playStationLEDColor = playStationLEDColor
        self.core = InputCore(sink: sender, surface: surface,
                              resolver: KeybindingResolver(keybindings),
                              mouseMode: mouseMode, playStationEmulation: playStationEmulation,
                              swapFaceButtons: swapFaceButtons, swapMouseButtons: swapMouseButtons,
                              swapWinAltKeys: swapWinAltKeys,
                              systemKeyCaptureActive: systemKeyCaptureActive, streamWidth: streamWidth,
                              streamHeight: streamHeight, onCommand: { continuation.yield($0) },
                              onTermination: { terminationsContinuation.yield($0) })
        self.core.onMenuNav = { menuContinuation.yield($0) }
    }

    public func setMenuOpen(_ open: Bool) {
        queue.async { [self] in core.setMenuOpen(open) }
    }

    public var packetsSent: Int { sender.packetsSent }

    public var inputStats: InputStats { sender.stats }

    public func start() {
        sender.enableHaptics()
        sender.start()

        let connect = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: nil) { [self] note in
            guard let c = note.object as? GCController else { return }
            let box = Unchecked(c)
            queue.async { self.attach(box.value) }
        }
        let disconnect = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: nil) { [self] note in
            guard let c = note.object as? GCController else { return }
            let box = Unchecked(c)
            queue.async { self.detach(box.value) }
        }
        // GCMouse/GCKeyboard drive the capture path (raw, off the main thread). Re-acquire on
        // GCMouseDidBecomeCurrent (fires on foreground round-trips; GCMouseDidConnect doesn't) so routing survives.
        let gcMouseConnect = NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect, object: nil, queue: nil) { [self] note in
            guard let m = note.object as? GCMouse else { return }
            let box = Unchecked(m); queue.async { self.attachMouse(box.value) }
        }
        let gcMouseCurrent = NotificationCenter.default.addObserver(
            forName: .GCMouseDidBecomeCurrent, object: nil, queue: nil) { [self] _ in
            queue.async { [self] in
                for m in GCMouse.mice() { attachMouse(m) }
                if let kb = GCKeyboard.coalesced { attachKeyboard(kb) }
            }
        }
        let gcKeyboardConnect = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: nil) { [self] note in
            guard let kb = note.object as? GCKeyboard else { return }
            let box = Unchecked(kb); queue.async { self.attachKeyboard(box.value) }
        }
        observers = [connect, disconnect, gcMouseConnect, gcMouseCurrent, gcKeyboardConnect]
        queue.async { [self] in
            core.setActuator(self)
            for c in GCController.controllers() { attach(c) }
            for m in GCMouse.mice() { attachMouse(m) }
            if let kb = GCKeyboard.coalesced { attachKeyboard(kb) }
            core.start()
            startRumbleWatchdog()
        }
    }

    /// Periodically expire rumble the host left latched on by going silent (crash, dropped stream).
    private func startRumbleWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.core.expireStaleRumble() }
        timer.resume()
        rumbleWatchdogTimer = timer
    }

    #if DEBUG
    /// Sweep each handle and trigger alone on the first controller, releasing each before the next.
    /// Tunes the floor and confirms lateralized feel.
    public func fireTestRumble() {
        queue.async { [self] in
            guard let slot = slots.firstIndex(where: { $0 != nil }) else { return }
            let sweep: [HapticLocality] = [.leftHandle, .rightHandle, .leftTrigger, .rightTrigger]
            var t = 0.0
            for locality in sweep { t = scheduleRamp(slot: slot, locality: locality, from: t) }
        }
    }

    /// Ramp `locality` 0.2→1.0 then off, release its engine. From `start`s out; returns the next.
    private func scheduleRamp(slot: Int, locality: HapticLocality, from start: Double) -> Double {
        var t = start
        for level in stride(from: Float(0.2), through: 1.0, by: 0.2) {
            queue.asyncAfter(deadline: .now() + t) { [self] in
                setIntensity(slot: slot, locality: locality, intensity: level)
            }
            t += 0.15
        }
        queue.asyncAfter(deadline: .now() + t) { [self] in
            setIntensity(slot: slot, locality: locality, intensity: 0)
            haptics[slot]?.release(Self.gcLocality(locality))
        }
        return t + 0.4
    }
    #endif

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                rumbleWatchdogTimer?.cancel()
                rumbleWatchdogTimer = nil
                for token in observers { NotificationCenter.default.removeObserver(token) }
                observers.removeAll()
                for controller in slots.compactMap({ $0 }) {
                    controller.extendedGamepad?.valueChangedHandler = nil
                }
                for m in GCMouse.mice() {
                    m.mouseInput?.mouseMovedHandler = nil
                    m.mouseInput?.scroll.valueChangedHandler = nil
                }
                GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
                haptics.forEach { $0?.invalidate() }
                haptics = [SlotHaptics?](repeating: nil, count: 16)
                slots = [GCController?](repeating: nil, count: 16)
                core.releaseForStop()
                continuation.resume()
            }
        }
        await sender.stop()
        commandsContinuation.finish()
        menuNavContinuation.finish()
        terminationsContinuation.finish()
    }

    private func attach(_ controller: GCController) {
        guard let gp = controller.extendedGamepad else { return }
        if slots.contains(where: { $0 === controller }) { return }
        guard let slot = slots.firstIndex(where: { $0 == nil }) else { return }

        slots[slot] = controller
        let index = UInt8(slot)
        if let playerIndex = GCControllerPlayerIndex(rawValue: slot) { controller.playerIndex = playerIndex }
        controller.handlerQueue = queue

        core.gamepadArrival(buildArrival(controller, gp: gp, index: index))
        if controller.isPlayStationController { applyLED(slot: slot, color: playStationLEDColor) }
        gp.valueChangedHandler = { [self] gp, _ in core.gamepadReading(Self.reading(from: gp), index: index) }
        core.gamepadReading(Self.reading(from: gp), index: index)   // seed an initial neutral snapshot
    }

    private func detach(_ controller: GCController) {
        guard let slot = slots.firstIndex(where: { $0 === controller }) else { return }
        let index = UInt8(slot)
        controller.extendedGamepad?.valueChangedHandler = nil
        haptics[slot]?.invalidate()
        haptics[slot] = nil
        slots[slot] = nil
        ledSmoothers[slot] = LEDSmoother()
        core.gamepadDisconnected(index: index)
    }

    /// GCMouse input path: raw callbacks off the main thread. Re-acquired on GCMouseDidBecomeCurrent to
    /// survive a foreground round-trip. GCMouse Y is up-positive; negate to the host's down-positive delta.
    private func attachMouse(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        mouse.handlerQueue = queue
        configureMouseMotion(input)
        input.leftButton.pressedChangedHandler = { [self] _, _, pressed in
            core.feedMouseButton(InputEncoder.mouseButtonLeft, down: pressed)
        }
        input.rightButton?.pressedChangedHandler = { [self] _, _, pressed in
            core.feedMouseButton(InputEncoder.mouseButtonRight, down: pressed)
        }
        input.middleButton?.pressedChangedHandler = { [self] _, _, pressed in
            core.feedMouseButton(InputEncoder.mouseButtonMiddle, down: pressed)
        }
        if let aux = input.auxiliaryButtons, aux.count >= 2 {
            aux[0].pressedChangedHandler = { [self] _, _, pressed in
                core.feedMouseButton(InputEncoder.mouseButtonX1, down: pressed)
            }
            aux[1].pressedChangedHandler = { [self] _, _, pressed in
                core.feedMouseButton(InputEncoder.mouseButtonX2, down: pressed)
            }
        }
        input.scroll.valueChangedHandler = { [self] _, x, y in
            core.feedScroll(preciseX: Double(x), preciseY: Double(y))
        }
    }

    private func configureMouseMotion(_ input: GCMouseInput) {
        input.mouseMovedHandler = { [self] _, dx, dy in
            if usesAbsolutePointer {
                core.feedAbsolutePointerDelta(deltaX: Double(dx), deltaY: -Double(dy))
            } else {
                core.feedRelativePointer(deltaX: Double(dx), deltaY: -Double(dy))
            }
        }
    }

    private func syncMouseMotionMode() {
        let absolute = core.usesAbsolutePointer
        guard absolute != usesAbsolutePointer else { return }
        usesAbsolutePointer = absolute
        for mouse in GCMouse.mice() {
            if let input = mouse.mouseInput { configureMouseMotion(input) }
        }
    }

    /// Routes GCKeyboard HID into `core.keyChanged` (same path as NSEvent capture) so all keybinding
    /// logic works unchanged; StreamCaptureView's NSEvent layer still swallows menu shortcuts while captured.
    private func attachKeyboard(_ keyboard: GCKeyboard) {
        guard let input = keyboard.keyboardInput else { return }
        keyboard.handlerQueue = queue
        input.keyChangedHandler = { [self] _, _, keyCode, pressed in
            core.keyChanged(scancode: Int(keyCode.rawValue), pressed: pressed)
            syncMouseMotionMode()
        }
    }

    public func setCaptureActive(_ active: Bool) {
        queue.async { [self] in core.setCapture(active) }
    }

    public func toggleMouseMode() {
        queue.async { [self] in
            core.toggleMouseMode()
            syncMouseMotionMode()
        }
    }

    // GCMouse/GCKeyboard drive mouse+keyboard raw, off the main thread; these NSEvent entries from
    // StreamCaptureView are inert (it owns focus/recapture) except feedAbsolutePointer for desktop mode.
    public func feedKey(scancode: Int, pressed: Bool) {}
    public func feedRelativePointer(deltaX: Double, deltaY: Double) {}
    public func feedMouseButton(_ button: LocalMouseButton, down: Bool) {}
    public func feedScroll(preciseX: Double, preciseY: Double) {}

    public func feedAbsolutePointer(viewX: Int, viewY: Int, viewWidth: Int, viewHeight: Int,
                                    eventAgeNanos: UInt64) {
        queue.async { [self] in
            core.feedAbsolutePointer(viewX: viewX, viewY: viewY, viewWidth: viewWidth,
                                     viewHeight: viewHeight, eventAgeNanos: eventAgeNanos)
        }
    }

    public func handle(_ message: HostControlMessage) {
        queue.async { [self] in core.handleHostMessage(message) }
    }


    func setIntensity(slot: Int, locality: HapticLocality, intensity: Float) {
        guard slot < 16, let store = slotHaptics(UInt16(slot)) else { return }
        store.channel(Self.gcLocality(locality))?.setIntensity(intensity)
    }

    func setLED(slot: Int, red: UInt8, green: UInt8, blue: UInt8) {
        guard slot < 16, let controller = slots[slot] else { return }
        guard !controller.isPlayStationController else { return }
        guard let c = ledSmoothers[slot].feed(red: red, green: green, blue: blue) else { return }
        let color = PlayStationLEDColor(red: c.red, green: c.green, blue: c.blue)
        applyLED(slot: slot, color: color)
    }

    private func applyLED(slot: Int, color: PlayStationLEDColor) {
        guard slot < 16, let light = slots[slot]?.light else { return }
        light.color = GCColor(red: Float(color.red) / 255 * color.brightness,
                              green: Float(color.green) / 255 * color.brightness,
                              blue: Float(color.blue) / 255 * color.brightness)
    }

    func setAdaptiveTrigger(slot: Int, side: TriggerSide, type: UInt8, effect: [UInt8]) {
        guard slot < 16, let ds = slots[slot]?.extendedGamepad as? GCDualSenseGamepad else { return }
        applyAdaptiveTrigger(side == .left ? ds.leftTrigger : ds.rightTrigger, type: type, effect: effect)
    }

    private static func gcLocality(_ locality: HapticLocality) -> GCHapticsLocality {
        switch locality {
        case .leftHandle: return .leftHandle
        case .rightHandle: return .rightHandle
        case .combined: return .default
        case .leftTrigger: return .leftTrigger
        case .rightTrigger: return .rightTrigger
        }
    }

    private func slotHaptics(_ controllerNumber: UInt16) -> SlotHaptics? {
        let slot = Int(controllerNumber)
        guard slot < 16, let controller = slots[slot] else { return nil }
        if let existing = haptics[slot] { return existing }
        guard let device = controller.haptics else { return nil }
        let store = SlotHaptics(device: device, queue: queue)
        haptics[slot] = store
        return store
    }

    private func applyAdaptiveTrigger(_ trigger: GCDualSenseAdaptiveTrigger, type: UInt8, effect: [UInt8]) {
        _ = (type, effect)
        trigger.setModeOff()
    }

    private func buildArrival(_ controller: GCController, gp: GCExtendedGamepad, index: UInt8) -> GamepadArrival {
        var supported = GamepadButton.a | GamepadButton.b | GamepadButton.x | GamepadButton.y
        supported |= GamepadButton.up | GamepadButton.down | GamepadButton.left | GamepadButton.right
        supported |= GamepadButton.leftButton | GamepadButton.rightButton | GamepadButton.play
        if gp.buttonOptions != nil { supported |= GamepadButton.back }
        if gp.buttonHome != nil { supported |= GamepadButton.special }
        if gp.leftThumbstickButton != nil { supported |= GamepadButton.leftStick }
        if gp.rightThumbstickButton != nil { supported |= GamepadButton.rightStick }
        if let xbox = gp as? GCXboxGamepad {
            if xbox.paddleButton1 != nil { supported |= GamepadButton.paddle1 }
            if xbox.paddleButton2 != nil { supported |= GamepadButton.paddle2 }
            if xbox.paddleButton3 != nil { supported |= GamepadButton.paddle3 }
            if xbox.paddleButton4 != nil { supported |= GamepadButton.paddle4 }
            if xbox.buttonShare != nil { supported |= GamepadButton.misc }
        }
        if controller.isPlayStationController { supported |= GamepadButton.touchpad }

        var caps = ControllerCapability.analogTriggers
        if controller.haptics != nil { caps |= ControllerCapability.rumble }
        if controller.battery != nil { caps |= ControllerCapability.batteryState }
        if controller.light != nil { caps |= ControllerCapability.rgbLed }

        let localities = controller.haptics?.supportedLocalities
        let split = localities?.contains(.leftHandle) == true && localities?.contains(.rightHandle) == true

        return GamepadArrival(index: index, type: Self.controllerType(controller),
                              supportedButtonFlags: supported, capabilities: caps,
                              battery: batterySample(controller), supportsSplitHandles: split)
    }

    private func batterySample(_ controller: GCController) -> BatterySample? {
        guard let battery = controller.battery else { return nil }
        let percentage = UInt8(max(0, min(1, battery.batteryLevel)) * 100)
        switch battery.batteryState {
        case .charging: return BatterySample(state: BatteryState.charging, percentage: percentage)
        case .full: return BatterySample(state: BatteryState.full, percentage: percentage)
        case .discharging: return BatterySample(state: BatteryState.discharging, percentage: percentage)
        default: return BatterySample(state: BatteryState.unknown, percentage: BatteryState.percentageUnknown)
        }
    }

    private static func reading(from gp: GCExtendedGamepad) -> GamepadReading {
        var r = GamepadReading()
        r.a = gp.buttonA.isPressed
        r.b = gp.buttonB.isPressed
        r.x = gp.buttonX.isPressed
        r.y = gp.buttonY.isPressed
        r.dpadUp = gp.dpad.up.isPressed
        r.dpadDown = gp.dpad.down.isPressed
        r.dpadLeft = gp.dpad.left.isPressed
        r.dpadRight = gp.dpad.right.isPressed
        r.leftShoulder = gp.leftShoulder.isPressed
        r.rightShoulder = gp.rightShoulder.isPressed
        r.menu = gp.buttonMenu.isPressed
        r.options = gp.buttonOptions?.isPressed ?? false
        r.home = gp.buttonHome?.isPressed ?? false
        r.leftThumbstickButton = gp.leftThumbstickButton?.isPressed ?? false
        r.rightThumbstickButton = gp.rightThumbstickButton?.isPressed ?? false
        if let xbox = gp as? GCXboxGamepad {
            r.paddle1 = xbox.paddleButton1?.isPressed ?? false
            r.paddle2 = xbox.paddleButton2?.isPressed ?? false
            r.paddle3 = xbox.paddleButton3?.isPressed ?? false
            r.paddle4 = xbox.paddleButton4?.isPressed ?? false
            r.share = xbox.buttonShare?.isPressed ?? false
        }
        if let ds = gp as? GCDualSenseGamepad { r.touchpad = ds.touchpadButton.isPressed }
        else if let ds = gp as? GCDualShockGamepad { r.touchpad = ds.touchpadButton.isPressed }
        r.leftTrigger = gp.leftTrigger.value
        r.rightTrigger = gp.rightTrigger.value
        r.leftStickX = gp.leftThumbstick.xAxis.value
        r.leftStickY = gp.leftThumbstick.yAxis.value
        r.rightStickX = gp.rightThumbstick.xAxis.value
        r.rightStickY = gp.rightThumbstick.yAxis.value
        return r
    }

    private static func controllerType(_ controller: GCController) -> UInt8 {
        if controller.extendedGamepad is GCXboxGamepad { return ControllerType.xbox }
        if controller.isPlayStationController { return ControllerType.playStation }
        let category = controller.productCategory
        if category.contains("Switch") || category.contains("Nintendo") { return ControllerType.nintendo }
        return ControllerType.unknown
    }
}
