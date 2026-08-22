import Testing
import GameStreamProtocol
import AsteriaModel
@testable import InputEngine

/// Records the local actions the core surfaces (controller combos, keyboard chords).
private final class CommandLog: @unchecked Sendable {
    private(set) var commands: [StreamAction] = []
    func record(_ command: StreamAction) { commands.append(command) }
}

/// Records input-state side effects so capture toggles are observable.
private final class FakeSurface: StreamSurface, @unchecked Sendable {
    struct State: Equatable {
        let active: Bool
        let mouseMode: MouseMode
    }

    private(set) var inputStates: [State] = []
    func applyInputState(active: Bool, mouseMode: MouseMode) {
        inputStates.append(State(active: active, mouseMode: mouseMode))
    }
}

@Suite("InputCore capture decisions")
struct InputCoreTests {
    private func makeCore(sink: RecordingSink, surface: StreamSurface? = nil,
                          keybindings: Keybindings = .defaults, mouseMode: MouseMode = .game,
                          playStationEmulation: PlayStationControllerEmulation = .playStation4,
                          swapFaceButtons: Bool = false, swapMouseButtons: Bool = false,
                          swapWinAlt: Bool = false, systemKeyCapture: Bool = false,
                          streamWidth: Int = 1920, streamHeight: Int = 1080,
                          onCommand: @escaping (StreamAction) -> Void = { _ in }) -> InputCore {
        InputCore(sink: sink, surface: surface, resolver: KeybindingResolver(keybindings),
                  mouseMode: mouseMode,
                  playStationEmulation: playStationEmulation,
                  swapFaceButtons: swapFaceButtons,
                  swapMouseButtons: swapMouseButtons, swapWinAltKeys: swapWinAlt,
                  systemKeyCaptureActive: systemKeyCapture, streamWidth: streamWidth,
                  streamHeight: streamHeight, onCommand: onCommand)
    }

    private func arrival(_ index: UInt8, split: Bool = false) -> GamepadArrival {
        GamepadArrival(index: index, type: ControllerType.unknown, supportedButtonFlags: 0,
                       capabilities: 0, battery: nil, supportsSplitHandles: split)
    }

    @Test("a bare key forwards the 0x8000-flagged VK with no modifiers")
    func bareKey() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink)
        core.keyChanged(scancode: 4, pressed: true)    // USB-HID 'a' → VK 0x41
        core.keyChanged(scancode: 4, pressed: false)
        let aWire = Int16(bitPattern: 0x8041)
        #expect(sink.events == [
            .keyboard(keyCode: aWire, down: true, modifiers: 0, flags: 0),
            .keyboard(keyCode: aWire, down: false, modifiers: 0, flags: 0),
        ])
    }

    @Test("Xbox emulation reports Sony controllers without PlayStation-only controls")
    func xboxEmulationReportsSonyController() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink, playStationEmulation: .xbox)
        core.gamepadArrival(GamepadArrival(
            index: 0, type: ControllerType.playStation,
            supportedButtonFlags: GamepadButton.a | GamepadButton.touchpad,
            capabilities: ControllerCapability.touchpad, battery: nil, supportsSplitHandles: false))

        #expect(sink.events == [
            .controllerArrival(index: 0, type: ControllerType.xbox, supported: GamepadButton.a,
                               capabilities: 0),
        ])

        var reading = GamepadReading()
        reading.a = true
        reading.touchpad = true
        core.gamepadReading(reading, index: 0)
        let snapshot: ControllerSnapshot?
        if case let .controller(value)? = sink.events.last {
            snapshot = value
        } else {
            snapshot = nil
        }
        #expect(snapshot?.buttonFlags == GamepadButton.a)
    }

    @Test("PlayStation 4 emulation preserves Sony controls")
    func playStation4EmulationPreservesSonyController() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink)
        let capabilities = ControllerCapability.touchpad | ControllerCapability.rgbLed
        core.gamepadArrival(GamepadArrival(
            index: 0, type: ControllerType.playStation,
            supportedButtonFlags: GamepadButton.a | GamepadButton.touchpad,
            capabilities: capabilities, battery: nil, supportsSplitHandles: false))

        #expect(sink.events == [
            .controllerArrival(index: 0, type: ControllerType.playStation,
                               supported: GamepadButton.a | GamepadButton.touchpad,
                               capabilities: capabilities),
        ])
    }

    @Test("a held modifier sets the host modifier byte on subsequent keys")
    func modifierByte() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink)
        core.keyChanged(scancode: 224, pressed: true)  // LCtrl (emits its own VK)
        sink.reset()
        core.keyChanged(scancode: 4, pressed: true)    // 'a' while Ctrl held
        #expect(sink.events == [.keyboard(keyCode: Int16(bitPattern: 0x8041), down: true, modifiers: 0x02, flags: 0)])
    }

    @Test("an international key carries the non-normalized flag")
    func nonNormalizedFlag() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink)
        core.keyChanged(scancode: 135, pressed: true)  // INTERNATIONAL1 → VK 0xE2, must not be re-normalized
        #expect(sink.events == [.keyboard(keyCode: Int16(bitPattern: 0x80E2), down: true,
                                          modifiers: 0, flags: InputEncoder.keyboardFlagNonNormalized)])
    }

    @Test("the stats chord (⌘⌥S) is consumed locally and not forwarded to the host")
    func comboConsumed() {
        let sink = RecordingSink()
        let log = CommandLog()
        let core = makeCore(sink: sink, onCommand: log.record)
        core.keyChanged(scancode: 227, pressed: true)  // LGui (⌘)
        core.keyChanged(scancode: 226, pressed: true)  // LAlt (⌥)
        core.keyChanged(scancode: 22, pressed: true)   // S → ⌘⌥S = toggleStats

        let sWire = Int16(bitPattern: 0x8053)
        let forwardedS = sink.events.contains {
            if case .keyboard(let kc, _, _, _) = $0 { return kc == sWire }
            return false
        }
        #expect(!forwardedS)              // S itself never reaches the host
        #expect(log.commands == [.toggleStats])
    }

    @Test("the grab chord (⌘⌥G) toggles capture and stops forwarding keys")
    func toggleCaptureCombo() {
        let sink = RecordingSink()
        let surface = FakeSurface()
        let log = CommandLog()
        let core = makeCore(sink: sink, surface: surface, onCommand: log.record)
        core.start()                                   // initial input state is active
        core.keyChanged(scancode: 227, pressed: true)  // ⌘
        core.keyChanged(scancode: 226, pressed: true)  // ⌥
        sink.reset()
        core.keyChanged(scancode: 10, pressed: true)   // G → ⌘⌥G = toggleInputCapture

        #expect(log.commands == [.toggleInputCapture])
        #expect(surface.inputStates == [
            .init(active: true, mouseMode: .game),
            .init(active: false, mouseMode: .game),
        ])

        // With capture off, a fresh key press is tracked but not forwarded.
        sink.reset()
        core.keyChanged(scancode: 4, pressed: true)
        #expect(sink.events.isEmpty)
    }

    @Test("a held mouse button is de-duped and released on uncapture")
    func heldMaskRelease() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink)
        core.feedMouseButton(InputEncoder.mouseButtonLeft, down: true)  // press → down
        core.feedMouseButton(InputEncoder.mouseButtonLeft, down: true)  // repeat → no dup
        core.setCapture(false)                                          // releases the held button
        #expect(sink.events == [
            .mouseButton(InputEncoder.mouseButtonLeft, down: true),
            .mouseButton(InputEncoder.mouseButtonLeft, down: false),
        ])
    }

    @Test("releasing a never-pressed button does nothing (no phantom release)")
    func phantomReleaseGuard() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink)
        core.feedMouseButton(InputEncoder.mouseButtonRight, down: false)
        #expect(sink.events.isEmpty)
    }

    @Test("in game mode the relative feed reaches the host; the absolute feed is gated")
    func relativeRoute() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink)
        core.feedRelativePointer(deltaX: 3, deltaY: -2)                                // relative route → emit
        core.feedAbsolutePointer(viewX: 10, viewY: 10, viewWidth: 100, viewHeight: 100) // gated (not absolute)
        #expect(sink.events == [.mouseMoveRelative(dx: 3, dy: -2)])
    }

    @Test("absolute mode routes pointer feeds to absolute and gates relative")
    func absoluteRoute() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink, streamWidth: 100, streamHeight: 100)
        core.setAbsoluteMouseMode(true)
        core.feedRelativePointer(deltaX: 3, deltaY: 3)                                 // gated (route absolute)
        core.feedAbsolutePointer(viewX: 50, viewY: 50, viewWidth: 100, viewHeight: 100) // emit absolute
        let absCount = sink.events.filter { if case .mouseMoveAbsolute = $0 { return true }; return false }.count
        let relCount = sink.events.filter { if case .mouseMoveRelative = $0 { return true }; return false }.count
        #expect(absCount == 1)
        #expect(relCount == 0)
    }

    @Test("desktop raw deltas update the seeded absolute position")
    func absoluteDeltaRoute() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink, mouseMode: .desktop, streamWidth: 100, streamHeight: 100)
        core.feedAbsolutePointer(viewX: 50, viewY: 50, viewWidth: 100, viewHeight: 100)
        sink.reset()

        core.feedAbsolutePointerDelta(deltaX: 10, deltaY: -5)

        #expect(sink.events == [
            .mouseMoveAbsolute(x: 60, y: 45, refW: 100, refH: 100),
        ])
    }

    @Test("desktop ignores stale AppKit positions after it has a raw pointer seed")
    func staleAbsolutePositionIsIgnored() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink, mouseMode: .desktop, streamWidth: 100, streamHeight: 100)
        core.feedAbsolutePointer(viewX: 50, viewY: 50, viewWidth: 100, viewHeight: 100)
        sink.reset()

        core.feedAbsolutePointerDelta(deltaX: 10, deltaY: 0)
        core.feedAbsolutePointer(viewX: 40, viewY: 50, viewWidth: 100, viewHeight: 100,
                                 eventAgeNanos: 11_000_000)

        #expect(sink.events == [
            .mouseMoveAbsolute(x: 60, y: 50, refW: 100, refH: 100),
        ])
    }

    @Test("switching to Desktop synchronously applies its input state")
    func desktopModeAppliesInputState() {
        let sink = RecordingSink()
        let surface = FakeSurface()
        let core = makeCore(sink: sink, surface: surface, streamWidth: 100, streamHeight: 100)
        core.start()

        core.toggleMouseMode()

        #expect(surface.inputStates == [
            .init(active: true, mouseMode: .game),
            .init(active: true, mouseMode: .desktop),
        ])
        #expect(sink.events.isEmpty)

        core.feedAbsolutePointer(viewX: 50, viewY: 50, viewWidth: 100, viewHeight: 100)
        #expect(sink.events == [
            .mouseMoveAbsolute(x: 50, y: 50, refW: 100, refH: 100),
        ])
    }

    @Test("swapMouseButtons exchanges left and right on app-fed buttons")
    func swapButtons() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink, swapMouseButtons: true)
        core.feedMouseButton(InputEncoder.mouseButtonLeft, down: true)   // relative route allows it
        #expect(sink.events == [.mouseButton(InputEncoder.mouseButtonRight, down: true)])
    }

    @Test("Desktop forwards every mouse button and both scroll axes")
    func desktopButtonsAndScroll() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink, mouseMode: .desktop)
        let buttons = [
            InputEncoder.mouseButtonLeft,
            InputEncoder.mouseButtonRight,
            InputEncoder.mouseButtonMiddle,
            InputEncoder.mouseButtonX1,
            InputEncoder.mouseButtonX2,
        ]

        for button in buttons {
            core.feedMouseButton(button, down: true)
            core.feedMouseButton(button, down: false)
        }
        core.feedScroll(preciseX: 2, preciseY: -2)

        #expect(sink.events == [
            .mouseButton(InputEncoder.mouseButtonLeft, down: true),
            .mouseButton(InputEncoder.mouseButtonLeft, down: false),
            .mouseButton(InputEncoder.mouseButtonRight, down: true),
            .mouseButton(InputEncoder.mouseButtonRight, down: false),
            .mouseButton(InputEncoder.mouseButtonMiddle, down: true),
            .mouseButton(InputEncoder.mouseButtonMiddle, down: false),
            .mouseButton(InputEncoder.mouseButtonX1, down: true),
            .mouseButton(InputEncoder.mouseButtonX1, down: false),
            .mouseButton(InputEncoder.mouseButtonX2, down: true),
            .mouseButton(InputEncoder.mouseButtonX2, down: false),
            .scrollVertical(-120),
            .scrollHorizontal(120),
        ])
    }

    @Test("the gamepad end-stream combo sends a neutral snapshot and surfaces .endStream once per press")
    func quitChord() {
        let sink = RecordingSink()
        let log = CommandLog()
        let core = makeCore(sink: sink, onCommand: log.record)
        core.gamepadArrival(arrival(0))
        sink.reset()                                   // ignore the arrival announcement
        var held = GamepadReading()
        held.menu = true; held.options = true; held.b = true   // Start+Select+B = endStream default
        core.gamepadReading(held, index: 0)            // chord becomes complete → fire
        core.gamepadReading(held, index: 0)            // still held → host stays neutral, no re-fire

        let neutral = ControllerSnapshot(reading: GamepadReading(), index: 0, activeMask: 0x0001)
        #expect(sink.events == [.controller(neutral), .controller(neutral)])
        #expect(log.commands == [.endStream])          // edge-triggered: exactly once

        // Releasing the combo re-arms it for the next press.
        core.gamepadReading(GamepadReading(), index: 0)
        var again = GamepadReading()
        again.menu = true; again.options = true; again.b = true
        core.gamepadReading(again, index: 0)
        #expect(log.commands == [.endStream, .endStream])
    }

    @Test("the mouse-mode chord (⌘⌥P) flips the route and surfaces .toggleMouseMode")
    func mouseModeChord() {
        let sink = RecordingSink()
        let log = CommandLog()
        let core = makeCore(sink: sink, mouseMode: .game, streamWidth: 100, streamHeight: 100,
                            onCommand: log.record)
        core.keyChanged(scancode: 227, pressed: true)  // ⌘
        core.keyChanged(scancode: 226, pressed: true)  // ⌥
        core.keyChanged(scancode: 19, pressed: true)   // P → ⌘⌥P = toggleMouseMode
        #expect(log.commands == [.toggleMouseMode])

        // Now in absolute mode: an absolute feed emits, a relative feed is gated.
        sink.reset()
        core.feedAbsolutePointer(viewX: 50, viewY: 50, viewWidth: 100, viewHeight: 100)
        core.feedRelativePointer(deltaX: 4, deltaY: 4)
        let absCount = sink.events.filter { if case .mouseMoveAbsolute = $0 { return true }; return false }.count
        #expect(absCount == 1)
    }

    @Test("toggleMouseMode (overlay menu) flips the route and emits one .toggleMouseMode, like the chord")
    func toggleMouseModeProgrammatic() {
        let sink = RecordingSink()
        let log = CommandLog()
        let core = makeCore(sink: sink, mouseMode: .game, streamWidth: 100, streamHeight: 100,
                            onCommand: log.record)
        core.toggleMouseMode()
        #expect(log.commands == [.toggleMouseMode])

        // Same effect as the chord: now in absolute mode, an absolute feed emits and a relative feed is gated.
        sink.reset()
        core.feedAbsolutePointer(viewX: 50, viewY: 50, viewWidth: 100, viewHeight: 100)
        core.feedRelativePointer(deltaX: 4, deltaY: 4)
        let absCount = sink.events.filter { if case .mouseMoveAbsolute = $0 { return true }; return false }.count
        #expect(absCount == 1)
    }

    @Test("a normal gamepad reading is forwarded with the active mask")
    func gamepadForwarded() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink)
        core.gamepadArrival(arrival(0))
        core.gamepadArrival(arrival(1))
        sink.reset()                                   // ignore the arrival announcements
        var r = GamepadReading(); r.a = true
        core.gamepadReading(r, index: 1)
        #expect(sink.events == [.controller(ControllerSnapshot(reading: r, index: 1, activeMask: 0x0003))])
    }

    @Test("releasing capture neutralizes the controller and suppresses readings until recapture")
    func gamepadSuppressedWhileReleased() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink)
        core.gamepadArrival(arrival(0))
        sink.reset()
        core.setCapture(false)                         // emit one neutral snapshot so held buttons don't stick
        var r = GamepadReading(); r.a = true
        core.gamepadReading(r, index: 0)               // suppressed: host must not see input behind the menu
        #expect(sink.events == [.controller(ControllerSnapshot(reading: GamepadReading(), index: 0, activeMask: 0x0001))])
        sink.reset()
        core.setCapture(true)
        core.gamepadReading(r, index: 0)               // recaptured: forwarding resumes
        #expect(sink.events == [.controller(ControllerSnapshot(reading: r, index: 0, activeMask: 0x0001))])
    }

    @Test("menu mode reroutes arrow keys and d-pad to navigation, not the host")
    func menuNavigation() {
        let sink = RecordingSink()
        var navs: [MenuNav] = []
        let core = makeCore(sink: sink)
        core.onMenuNav = { navs.append($0) }
        core.gamepadArrival(arrival(0))
        sink.reset()
        core.setMenuOpen(true)

        core.keyChanged(scancode: 81, pressed: true)   // Down
        core.keyChanged(scancode: 82, pressed: true)   // Up
        core.keyChanged(scancode: 40, pressed: true)   // Return → select
        core.keyChanged(scancode: 41, pressed: true)   // Escape → back
        #expect(navs == [.down, .up, .select, .back])
        #expect(sink.events.isEmpty)                   // nothing forwarded to the host

        navs.removeAll()
        var down = GamepadReading(); down.dpadDown = true
        core.gamepadReading(down, index: 0)            // rising edge → one .down
        core.gamepadReading(down, index: 0)            // still held → no repeat
        var select = GamepadReading(); select.a = true
        core.gamepadReading(select, index: 0)
        #expect(navs == [.down, .select])
        #expect(sink.events.isEmpty)
    }

    @Test("a disconnect clears the slot bit and sends a zeroed snapshot")
    func gamepadDisconnect() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink)
        core.gamepadArrival(arrival(0))
        core.gamepadArrival(arrival(1))
        sink.reset()
        core.gamepadDisconnected(index: 0)
        #expect(sink.events == [.controller(ControllerSnapshot(reading: GamepadReading(), index: 0, activeMask: 0x0002))])
    }
}
