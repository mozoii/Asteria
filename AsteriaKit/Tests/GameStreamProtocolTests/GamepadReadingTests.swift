import Testing
@testable import GameStreamProtocol

@Suite("Gamepad reading → controller snapshot")
struct GamepadReadingTests {
    @Test func everyButtonMapsToItsFlag() {
        var r = GamepadReading()
        r.a = true; r.b = true; r.x = true; r.y = true
        r.dpadUp = true; r.dpadDown = true; r.dpadLeft = true; r.dpadRight = true
        r.leftShoulder = true; r.rightShoulder = true
        r.menu = true; r.options = true; r.home = true
        r.leftThumbstickButton = true; r.rightThumbstickButton = true
        r.paddle1 = true; r.paddle2 = true; r.paddle3 = true; r.paddle4 = true
        r.share = true; r.touchpad = true

        let snap = ControllerSnapshot(reading: r, index: 0, activeMask: 0x0001)
        let faces = GamepadButton.a | GamepadButton.b | GamepadButton.x | GamepadButton.y
        let dpad = GamepadButton.up | GamepadButton.down | GamepadButton.left | GamepadButton.right
        let shoulders = GamepadButton.leftButton | GamepadButton.rightButton
        let menus = GamepadButton.play | GamepadButton.back | GamepadButton.special
        let sticks = GamepadButton.leftStick | GamepadButton.rightStick
        let paddles = GamepadButton.paddle1 | GamepadButton.paddle2 | GamepadButton.paddle3 | GamepadButton.paddle4
        let extras = GamepadButton.misc | GamepadButton.touchpad
        let expected = faces | dpad | shoulders | menus | sticks | paddles | extras
        #expect(snap.buttonFlags == expected)
    }

    @Test func faceButtonSwapExchangesABandXY() {
        var r = GamepadReading()
        r.a = true; r.x = true
        #expect(ControllerSnapshot(reading: r, index: 0, activeMask: 1).buttonFlags
                == (GamepadButton.a | GamepadButton.x))
        #expect(ControllerSnapshot(reading: r, index: 0, activeMask: 1, swapFaceButtons: true).buttonFlags
                == (GamepadButton.b | GamepadButton.y))
    }

    @Test func triggersScaleAndTruncateTo0_255() {
        func lt(_ v: Float) -> UInt8 {
            var r = GamepadReading(); r.leftTrigger = v
            return ControllerSnapshot(reading: r, index: 0, activeMask: 1).leftTrigger
        }
        #expect(lt(0) == 0)
        #expect(lt(1) == 255)
        #expect(lt(0.5) == 127)   // truncate
        #expect(lt(2) == 255)     // clamp
        #expect(lt(-1) == 0)      // clamp
    }

    @Test func sticksScaleTruncateAndDoNotInvertY() {
        func axis(_ v: Float, _ kp: (ControllerSnapshot) -> Int16) -> Int16 {
            var r = GamepadReading()
            r.leftStickX = v; r.leftStickY = v
            return kp(ControllerSnapshot(reading: r, index: 0, activeMask: 1))
        }
        #expect(axis(1.0) { $0.leftStickX } == 32767)
        #expect(axis(-1.0) { $0.leftStickX } == -32767)
        #expect(axis(0) { $0.leftStickX } == 0)
        #expect(axis(0.5) { $0.leftStickX } == 16383)   // truncate
        #expect(axis(1.0) { $0.leftStickY } == 32767)   // Y positive = up (no inversion)
        #expect(axis(2.0) { $0.leftStickX } == 32767)   // clamp
    }

    @Test func indexAndMaskPassThrough() {
        let snap = ControllerSnapshot(reading: GamepadReading(), index: 3, activeMask: 0x000F)
        #expect(snap.index == 3)
        #expect(snap.activeMask == 0x000F)
        #expect(snap.buttonFlags == 0)
    }
}
