import Dispatch
import GameStreamProtocol
import AsteriaModel
import Synchronization

/// Synchronous input-capture core: translation, capture-state decisions, and host-event writing. Not Sendable; confined to the engine's queue.
final class InputCore {
    private let sink: InputSink
    private let surface: StreamSurface?
    private let onCommand: (StreamAction) -> Void
    private let onTermination: (UInt32) -> Void
    private let resolver: KeybindingResolver
    private let playStationEmulation: PlayStationControllerEmulation
    private let swapFaceButtons: Bool
    private let swapMouseButtons: Bool
    private let swapWinAltKeys: Bool
    private let systemKeyCaptureActive: Bool
    private let streamWidth: Int
    private let streamHeight: Int

    private var captureActive = true
    private var absoluteMouseMode = false
    private var absolutePointer: (x: Double, y: Double, width: Int, height: Int)?
    private var trackedMods = KeyModifiers()
    private var keysDown = Set<Int16>()
    private var motion = MouseMotionAccumulator()
    private var mouseButtonMask: UInt8 = 0
    private var mask: UInt16 = 0
    private var splitHandles = [Bool](repeating: false, count: 16)
    private var playStationSlots = [Bool](repeating: false, count: 16)
    private var chordLatched = [Bool](repeating: false, count: 16)
    private var menuOpen = false
    private var navHeld = [UInt8](repeating: 0, count: 16)
    private weak var actuator: DeviceActuator?
    private let counts = Mutex(InboundControlCounts())
    private let rumbleWatchdog = RumbleWatchdog()
    private let now: () -> UInt64

    /// While the menu is open, arrow keys + d-pad/A/B drive menu navigation.
    var onMenuNav: ((MenuNav) -> Void)?

    init(sink: InputSink, surface: StreamSurface?, resolver: KeybindingResolver,
         mouseMode: MouseMode,
         playStationEmulation: PlayStationControllerEmulation = .playStation4,
         swapFaceButtons: Bool, swapMouseButtons: Bool,
         swapWinAltKeys: Bool, systemKeyCaptureActive: Bool, streamWidth: Int, streamHeight: Int,
          now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
          onCommand: @escaping (StreamAction) -> Void,
          onTermination: @escaping (UInt32) -> Void = { _ in }) {
        self.sink = sink
        self.now = now
        self.surface = surface
        self.resolver = resolver
        self.absoluteMouseMode = mouseMode.usesAbsolutePointer
        self.playStationEmulation = playStationEmulation
        self.swapFaceButtons = swapFaceButtons
        self.swapMouseButtons = swapMouseButtons
        self.swapWinAltKeys = swapWinAltKeys
        self.systemKeyCaptureActive = systemKeyCaptureActive
        self.streamWidth = streamWidth
        self.streamHeight = streamHeight
        self.onCommand = onCommand
        self.onTermination = onTermination
    }

    /// Apply initial pointer-capture state (captured by default).
    func start() { applyInputState() }

    /// Teardown: raise held keys and uncapture.
    func releaseForStop() {
        raiseAllKeys()
        surface?.applyInputState(active: false, mouseMode: mouseMode)
    }

    /// Wire the device actuator. Set once before any host message.
    func setActuator(_ actuator: DeviceActuator) { self.actuator = actuator }

    /// Host control messages handled so far, by kind (read off-queue — guarded).
    var inboundCounts: InboundControlCounts { counts.withLock { $0 } }

    var usesAbsolutePointer: Bool { absoluteMouseMode }

    /// Client ORs `0x8000` into every keyboard keyCode; core applies it.
    private static let keyboardKeyCodeFlag: UInt16 = 0x8000

    /// Seed tracked modifiers from live state at keyboard attach (the shell reads GameController).
    func seedModifiers(_ mods: KeyModifiers) { trackedMods = mods }

    func keyChanged(scancode: Int, pressed: Bool) {
        trackedMods.update(scancode: scancode, pressed: pressed)
        guard scancode > 0, scancode < 512 else { return }

        if pressed, let action = resolver.keyboardAction(scancode: scancode, modifiers: trackedMods) {
            performCommand(action)
            return
        }

        if menuOpen, let nav = Self.menuKeyNav(scancode: scancode) {
            if pressed { onMenuNav?(nav) }
            return
        }

        guard let mapped = HostKeymap.map(scancode: scancode, swapWinAlt: swapWinAltKeys,
                                          systemKeyCaptureActive: systemKeyCaptureActive) else { return }
        let wire = Int16(bitPattern: Self.keyboardKeyCodeFlag | UInt16(bitPattern: mapped.keyCode))
        if pressed { keysDown.insert(wire) } else { keysDown.remove(wire) }
        guard captureActive else { return }
        let modifiers = trackedMods.hostModifierByte(swapWinAlt: swapWinAltKeys,
                                                     systemKeyCaptureActive: systemKeyCaptureActive)
        let flags: UInt8 = mapped.nonNormalized ? InputEncoder.keyboardFlagNonNormalized : 0
        sink.keyboard(keyCode: wire, down: pressed, modifiers: modifiers, flags: flags)
    }

    private func releaseHeldControllers() {
        for slot in 0..<16 where mask & (UInt16(1) << slot) != 0 {
            sink.controller(ControllerSnapshot(reading: GamepadReading(), index: UInt8(slot), activeMask: mask))
        }
    }

    private func raiseAllKeys() {
        for key in keysDown { sink.keyboard(keyCode: key, down: false, modifiers: 0, flags: 0) }
        keysDown.removeAll(keepingCapacity: true)
    }

    private func performCommand(_ action: StreamAction) {
        switch action {
        case .toggleInputCapture:
            setCapture(!captureActive)
        case .toggleMouseMode:
            setAbsoluteMouseMode(!absoluteMouseMode)
            raiseAllKeys()
        case .toggleOverlayMenu, .endStream, .toggleFullscreen, .toggleStats, .toggleMute:
            raiseAllKeys()
        }
        onCommand(action)
    }

    func toggleMouseMode() { performCommand(.toggleMouseMode) }

    private func sendMouseButton(_ button: UInt8, down: Bool) {
        var b = button
        if swapMouseButtons {
            if b == InputEncoder.mouseButtonLeft { b = InputEncoder.mouseButtonRight }
            else if b == InputEncoder.mouseButtonRight { b = InputEncoder.mouseButtonLeft }
        }
        sink.mouseButton(b, down: down)
    }

    private func deliveryRoute() -> MouseRoute {
        MouseRoute.resolve(absoluteMode: absoluteMouseMode)
    }

    private var mouseMode: MouseMode { absoluteMouseMode ? .desktop : .game }

    private func applyInputState() {
        surface?.applyInputState(active: captureActive, mouseMode: mouseMode)
    }

    private func releaseHeldMouseButtons() {
        for (button, bit): (UInt8, UInt8) in [
            (InputEncoder.mouseButtonLeft, 0x01), (InputEncoder.mouseButtonRight, 0x02),
            (InputEncoder.mouseButtonMiddle, 0x04), (InputEncoder.mouseButtonX1, 0x08),
            (InputEncoder.mouseButtonX2, 0x10),
        ] where mouseButtonMask & bit != 0 {
            sendMouseButton(button, down: false)
        }
        mouseButtonMask = 0
    }

    func setCapture(_ active: Bool) {
        if active != captureActive {
            captureActive = active
            if !active {
                raiseAllKeys()
                releaseHeldMouseButtons()
                releaseHeldControllers()
            } else {
                motion.reset()   // drop fractional motion on re-capture
            }
        }
        // Push state back unconditionally so the surface's display flag re-syncs even on a redundant request.
        applyInputState()
    }

    func setAbsoluteMouseMode(_ enabled: Bool) {
        absoluteMouseMode = enabled
        absolutePointer = nil
        motion.reset()
        applyInputState()
    }

    func feedAbsolutePointer(viewX: Int, viewY: Int, viewWidth: Int, viewHeight: Int,
                             eventAgeNanos: UInt64 = 0) {
        guard captureActive, deliveryRoute() == .absolute else { return }
        if absolutePointer != nil && eventAgeNanos > 10_000_000 { return }
        absolutePointer = (Double(viewX), Double(viewY), viewWidth, viewHeight)
        sendAbsolutePointer()
    }

    func feedAbsolutePointerDelta(deltaX: Double, deltaY: Double) {
        guard captureActive, deliveryRoute() == .absolute else { return }
        guard var pointer = absolutePointer else { return }
        pointer.x += deltaX
        pointer.y += deltaY
        absolutePointer = pointer
        sendAbsolutePointer()
    }

    private func sendAbsolutePointer() {
        guard let pointer = absolutePointer else { return }
        guard let m = AbsoluteMouse.map(pointX: Int(pointer.x), pointY: Int(pointer.y),
                                        streamWidth: streamWidth, streamHeight: streamHeight,
                                        viewWidth: pointer.width,
                                        viewHeight: pointer.height) else { return }
        sink.mouseMoveAbsolute(x: m.x, y: m.y, referenceWidth: m.refW, referenceHeight: m.refH)
    }

    func feedRelativePointer(deltaX: Double, deltaY: Double) {
        guard captureActive, deliveryRoute() == .relative else { return }
        let (dx, dy) = motion.consume(deltaX: deltaX, deltaY: deltaY)
        if dx != 0 || dy != 0 { sink.mouseMoveRelative(deltaX: dx, deltaY: dy) }
    }

    /// Track the held button so an uncapture (focus loss while held) releases it instead of stranding it down on the host.
    func feedMouseButton(_ button: UInt8, down: Bool) {
        guard captureActive else { return }
        let bit = Self.buttonBit(button)
        if down {
            guard mouseButtonMask & bit == 0 else { return }
            mouseButtonMask |= bit
            sendMouseButton(button, down: true)
        } else {
            guard mouseButtonMask & bit != 0 else { return }
            mouseButtonMask &= ~bit
            sendMouseButton(button, down: false)
        }
    }

    private static func buttonBit(_ button: UInt8) -> UInt8 {
        switch button {
        case InputEncoder.mouseButtonLeft: return 0x01
        case InputEncoder.mouseButtonRight: return 0x02
        case InputEncoder.mouseButtonMiddle: return 0x04
        case InputEncoder.mouseButtonX1: return 0x08
        case InputEncoder.mouseButtonX2: return 0x10
        default: return 0
        }
    }

    func feedScroll(preciseX: Double, preciseY: Double) {
        guard captureActive else { return }
        let v = Int(MouseScroll.amount(precise: preciseY))
        if v != 0 { sink.scrollVertical(v) }
        let h = Int(MouseScroll.amount(precise: preciseX))
        if h != 0 { sink.scrollHorizontal(h) }
    }

    /// Controller connected: mark slot active, announce identity/battery.
    func gamepadArrival(_ arrival: GamepadArrival) {
        mask |= (UInt16(1) << arrival.index)
        let slot = Int(arrival.index)
        if slot < 16 {
            splitHandles[slot] = arrival.supportsSplitHandles
            playStationSlots[slot] = arrival.type == ControllerType.playStation
        }
        let emulated = emulatedArrival(arrival)
        sink.controllerArrival(index: emulated.index, type: emulated.type,
                               supportedButtonFlags: emulated.supportedButtonFlags,
                               capabilities: emulated.capabilities)
        if let battery = arrival.battery {
            sink.controllerBattery(index: arrival.index, state: battery.state, percentage: battery.percentage)
        }
    }

    private func emulatedArrival(_ arrival: GamepadArrival) -> GamepadArrival {
        guard arrival.type == ControllerType.playStation, playStationEmulation == .xbox else {
            return arrival
        }
        let unsupported = ControllerCapability.touchpad | ControllerCapability.accelerometer
            | ControllerCapability.gyro | ControllerCapability.rgbLed
        let supported = arrival.supportedButtonFlags & ~GamepadButton.touchpad
        let capabilities = arrival.capabilities & ~unsupported
        return GamepadArrival(
            index: arrival.index,
            type: ControllerType.xbox,
            supportedButtonFlags: supported,
            capabilities: capabilities,
            battery: arrival.battery,
            supportsSplitHandles: arrival.supportsSplitHandles)
    }

    func gamepadDisconnected(index: UInt8) {
        mask &= ~(UInt16(1) << index)
        if Int(index) < 16 {
            splitHandles[Int(index)] = false
            playStationSlots[Int(index)] = false
            chordLatched[Int(index)] = false
        }
        // Send zeroed snapshot to announce controller gone
        sink.controller(ControllerSnapshot(reading: GamepadReading(), index: index, activeMask: mask))
    }

    func gamepadReading(_ reading: GamepadReading, index: UInt8) {
        var reading = reading
        let slot = Int(index)
        if slot < 16, playStationSlots[slot], playStationEmulation == .xbox {
            reading.touchpad = false
        }
        let snapshot = ControllerSnapshot(reading: reading, index: index, activeMask: mask,
                                          swapFaceButtons: swapFaceButtons)
        if let action = resolver.gamepadAction(buttonFlags: snapshot.buttonFlags) {
            if slot < 16, !chordLatched[slot] {
                chordLatched[slot] = true
                onCommand(action)
            }
            sink.controller(ControllerSnapshot(reading: GamepadReading(), index: index, activeMask: mask))
            return
        }
        if slot < 16 { chordLatched[slot] = false }
        if menuOpen {
            if slot < 16 { emitGamepadNav(reading, slot: slot) }
            return
        }
        guard captureActive else { return }
        sink.controller(snapshot)
    }

    func setMenuOpen(_ open: Bool) {
        menuOpen = open
        if !open { navHeld = [UInt8](repeating: 0, count: 16) }
    }

    private static func menuKeyNav(scancode: Int) -> MenuNav? {
        switch scancode {
        case 82: return .up
        case 81: return .down
        case 40, 88: return .select
        case 41: return .back
        default: return nil
        }
    }

    private func emitGamepadNav(_ reading: GamepadReading, slot: Int) {
        let bits: [(held: Bool, bit: UInt8, nav: MenuNav)] = [
            (reading.dpadUp, 0x1, .up), (reading.dpadDown, 0x2, .down),
            (reading.a, 0x4, .select), (reading.b, 0x8, .back),
        ]
        for (held, bit, nav) in bits {
            let was = navHeld[slot] & bit != 0
            if held && !was { onMenuNav?(nav) }
            if held { navHeld[slot] |= bit } else { navHeld[slot] &= ~bit }
        }
    }

    func handleHostMessage(_ message: HostControlMessage) {
        switch message {
        case let .rumble(cn, low, high):
            counts.withLock { $0.rumble += 1 }
            let slot = Int(cn)
            if slot < 16 && splitHandles[slot] {
                driveRumble(slot: slot, locality: .leftHandle, motor: low)
                driveRumble(slot: slot, locality: .rightHandle, motor: high)
            } else {
                driveRumble(slot: slot, locality: .combined,
                            intensity: HapticCurve.combinedIntensity(low: low, high: high),
                            active: low != 0 || high != 0)
            }
        case let .rumbleTriggers(cn, left, right):
            counts.withLock { $0.rumbleTriggers += 1 }
            let slot = Int(cn)
            driveRumble(slot: slot, locality: .leftTrigger, motor: left)
            driveRumble(slot: slot, locality: .rightTrigger, motor: right)
        case let .setControllerLED(cn, r, g, b):
            counts.withLock { $0.led += 1 }
            actuator?.setLED(slot: Int(cn), red: r, green: g, blue: b)
        case let .setAdaptiveTriggers(cn, _, typeLeft, typeRight, left, right):
            counts.withLock { $0.adaptiveTriggers += 1 }
            let slot = Int(cn)
            actuator?.setAdaptiveTrigger(slot: slot, side: .left, type: typeLeft, effect: left)
            actuator?.setAdaptiveTrigger(slot: slot, side: .right, type: typeRight, effect: right)
        case .setMotionEventState:
            counts.withLock { $0.motion += 1 }
        case .setHdrMode:
            counts.withLock { $0.hdr += 1 }
        case let .termination(errorCode):
            counts.withLock { $0.termination += 1 }
            onTermination(errorCode)
        case .unknown:
            counts.withLock { $0.unknown += 1 }
        }
    }

    /// Drive one rumble locality from a raw motor value.
    private func driveRumble(slot: Int, locality: HapticLocality, motor: UInt16) {
        driveRumble(slot: slot, locality: locality,
                    intensity: HapticCurve.motorIntensity(motor), active: motor != 0)
    }

    /// Forward intensity and keep the watchdog current: non-zero arms the timeout, zero clears it.
    private func driveRumble(slot: Int, locality: HapticLocality, intensity: Float, active: Bool) {
        let key = RumbleKey(slot: slot, locality: locality)
        if active { rumbleWatchdog.active(key, at: now()) } else { rumbleWatchdog.idle(key) }
        actuator?.setIntensity(slot: slot, locality: locality, intensity: intensity)
    }

    /// Force any locality silent past the watchdog timeout to zero. Driven by a periodic timer.
    func expireStaleRumble() {
        for key in rumbleWatchdog.expired(now: now()) {
            actuator?.setIntensity(slot: key.slot, locality: key.locality, intensity: 0)
            rumbleWatchdog.idle(key)
        }
    }
}
