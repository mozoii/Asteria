import Testing
@testable import GameStreamProtocol

@Suite("Input encoder (gen7 input wire)")
struct InputEncoderTests {
    @Test func inputDataTypeAndMessageWrapping() {
        let p = InputEncoder.mouseButton(InputEncoder.mouseButtonLeft, down: true)
        #expect(InputEncoder.inputDataType == 0x0206)
        #expect(p.message.type == 0x0206)
        #expect(p.message.payload == p.payload)
    }

    @Test func relativeMouseMoveIsBigEndianDeltas() {
        // magic MOUSE_MOVE_REL_MAGIC_GEN5 = 0x07; deltas big-endian. deltaX=0x0102, deltaY=-2.
        let p = InputEncoder.mouseMoveRelative(deltaX: 0x0102, deltaY: -2)
        #expect(p.channel == 0x03)   // CTRL_CHANNEL_MOUSE
        #expect(p.payload == [
            0x00, 0x00, 0x00, 0x08,   // size BE32 = magic(4)+body(4)
            0x07, 0x00, 0x00, 0x00,   // magic LE32
            0x01, 0x02,               // deltaX BE16
            0xFF, 0xFE,               // deltaY BE16 (−2)
        ])
    }

    @Test func absoluteMouseMoveSubtractsOneFromReference() {
        // magic MOUSE_MOVE_ABS_MAGIC = 0x05; x/y/width/height big-endian; width/height are reference−1.
        let p = InputEncoder.mouseMoveAbsolute(x: 100, y: 200, referenceWidth: 1280, referenceHeight: 720)
        #expect(p.channel == 0x03)
        #expect(p.payload == [
            0x00, 0x00, 0x00, 0x0E,   // size BE32 = 4+10
            0x05, 0x00, 0x00, 0x00,   // magic LE32
            0x00, 0x64,               // x = 100 BE16
            0x00, 0xC8,               // y = 200 BE16
            0x00, 0x00,               // unused
            0x04, 0xFF,               // width−1 = 1279 BE16
            0x02, 0xCF,               // height−1 = 719 BE16
        ])
    }

    @Test func mouseButtonDownAndUpMagics() {
        // gen5: PRESS(0x07)+1 = 0x08 down, RELEASE(0x08)+1 = 0x09 up.
        let down = InputEncoder.mouseButton(InputEncoder.mouseButtonLeft, down: true)
        #expect(down.channel == 0x03)
        #expect(down.payload == [0x00, 0x00, 0x00, 0x05, 0x08, 0x00, 0x00, 0x00, 0x01])

        let up = InputEncoder.mouseButton(InputEncoder.mouseButtonRight, down: false)
        #expect(up.payload == [0x00, 0x00, 0x00, 0x05, 0x09, 0x00, 0x00, 0x00, 0x03])
    }

    @Test func verticalScrollDuplicatesAmountBigEndian() {
        // magic SCROLL_MAGIC_GEN5 = 0x0A; scrollAmt1 == scrollAmt2, big-endian; zero3 trailing.
        let p = InputEncoder.scrollVertical(amount: InputEncoder.wheelDelta)   // 120
        #expect(p.channel == 0x03)
        #expect(p.payload == [
            0x00, 0x00, 0x00, 0x0A,
            0x0A, 0x00, 0x00, 0x00,
            0x00, 0x78,               // amount = 120 BE16
            0x00, 0x78,               // duplicated
            0x00, 0x00,               // zero3
        ])

        let neg = InputEncoder.scrollVertical(amount: -120)
        #expect(neg.payload == [0x00, 0x00, 0x00, 0x0A, 0x0A, 0x00, 0x00, 0x00,
                                0xFF, 0x88, 0xFF, 0x88, 0x00, 0x00])
    }

    @Test func horizontalScrollIsSunshineExtension() {
        // magic SS_HSCROLL_MAGIC = 0x55000001; amount big-endian.
        let p = InputEncoder.scrollHorizontal(amount: 120)
        #expect(p.channel == 0x03)
        #expect(p.payload == [
            0x00, 0x00, 0x00, 0x06,
            0x01, 0x00, 0x00, 0x55,   // magic LE32 of 0x55000001
            0x00, 0x78,
        ])
    }

    @Test func keyboardDownLittleEndianKeycode() {
        // magic KEY_DOWN = 0x03; flags, keyCode LE16, modifiers, zero2. VK_A=0x41, MODIFIER_CTRL=0x02.
        let p = InputEncoder.keyboard(keyCode: 0x41, down: true, modifiers: InputEncoder.modifierCtrl)
        #expect(p.channel == 0x02)   // CTRL_CHANNEL_KEYBOARD
        #expect(p.payload == [
            0x00, 0x00, 0x00, 0x0A,   // size BE32 = 4+6
            0x03, 0x00, 0x00, 0x00,   // magic LE32 (down)
            0x00,                     // flags
            0x41, 0x00,               // keyCode LE16
            0x02,                     // modifiers (CTRL)
            0x00, 0x00,               // zero2
        ])
    }

    @Test func keyboardUpWithNonNormalizedFlag() {
        // magic KEY_UP = 0x04; SS_KBE_FLAG_NON_NORMALIZED = 0x01. keyCode 0xE2 (NONUSBACKSLASH VK).
        let p = InputEncoder.keyboard(keyCode: 0xE2, down: false, modifiers: 0,
                                      flags: InputEncoder.keyboardFlagNonNormalized)
        #expect(p.payload == [
            0x00, 0x00, 0x00, 0x0A,
            0x04, 0x00, 0x00, 0x00,   // magic LE32 (up)
            0x01,                     // flags = non-normalized
            0xE2, 0x00,               // keyCode LE16
            0x00,                     // modifiers
            0x00, 0x00,
        ])
    }

    @Test func multiControllerSplitsButtonFlagsAcrossLowAndHigh16() {
        // magic MULTI_CONTROLLER_MAGIC_GEN5 = 0x0C. buttonFlags 0x00011000:
        // low16 0x1000 (A_FLAG) → buttonFlags, high16 0x0001 (PADDLE1_FLAG) → buttonFlags2 (Sunshine).
        let p = InputEncoder.multiController(
            index: 0, activeMask: 0x0001, buttonFlags: 0x0001_1000,
            leftTrigger: 0x80, rightTrigger: 0xFF,
            leftStickX: 0x1234, leftStickY: -1, rightStickX: 0x00FF, rightStickY: 0x7FFF)
        #expect(p.channel == 0x10)   // CTRL_CHANNEL_GAMEPAD_BASE + 0
        #expect(p.payload == [
            0x00, 0x00, 0x00, 0x1E,   // size BE32 = 4+26
            0x0C, 0x00, 0x00, 0x00,   // magic LE32
            0x1A, 0x00,               // headerB (MC_HEADER_B)
            0x00, 0x00,               // controllerNumber
            0x01, 0x00,               // activeGamepadMask
            0x14, 0x00,               // midB (MC_MID_B)
            0x00, 0x10,               // buttonFlags low16 (A_FLAG) LE
            0x80,                     // leftTrigger
            0xFF,                     // rightTrigger
            0x34, 0x12,               // leftStickX LE
            0xFF, 0xFF,               // leftStickY (−1) LE
            0xFF, 0x00,               // rightStickX (0x00FF) LE
            0xFF, 0x7F,               // rightStickY (0x7FFF) LE
            0x9C, 0x00,               // tailA (MC_TAIL_A)
            0x01, 0x00,               // buttonFlags2 high16 (PADDLE1_FLAG) LE
            0x55, 0x00,               // tailB (MC_TAIL_B)
        ])
    }

    @Test func controllerArrivalIsLittleEndianSunshine() {
        // magic SS_CONTROLLER_ARRIVAL_MAGIC = 0x55000004. caps/supportedButtonFlags LE.
        let p = InputEncoder.controllerArrival(
            index: 0, type: 0x01 /* LI_CTYPE_XBOX */,
            supportedButtonFlags: 0x0001_23AB, capabilities: 0x0003 /* ANALOG_TRIGGERS|RUMBLE */)
        #expect(p.channel == 0x10)
        #expect(p.payload == [
            0x00, 0x00, 0x00, 0x0C,   // size BE32 = 4+8
            0x04, 0x00, 0x00, 0x55,   // magic LE32 of 0x55000004
            0x00,                     // controllerNumber
            0x01,                     // type (XBOX)
            0x03, 0x00,               // capabilities LE16
            0xAB, 0x23, 0x01, 0x00,   // supportedButtonFlags LE32
        ])
    }

    @Test func controllerBatteryOnGamepadChannel() {
        // magic SS_CONTROLLER_BATTERY_MAGIC = 0x55000007. index 1 → channel 0x11.
        let p = InputEncoder.controllerBattery(index: 1, state: 0x03 /* CHARGING */, percentage: 100)
        #expect(p.channel == 0x11)
        #expect(p.payload == [
            0x00, 0x00, 0x00, 0x08,
            0x07, 0x00, 0x00, 0x55,   // magic LE32 of 0x55000007
            0x01, 0x03, 0x64, 0x00,   // index, state, percentage, zero
        ])
    }

    @Test func enableHapticsOnGenericChannel() {
        // magic ENABLE_HAPTICS_MAGIC = 0x0D; enable = 1 LE16; CTRL_CHANNEL_GENERIC.
        let p = InputEncoder.enableHaptics()
        #expect(p.channel == 0x00)
        #expect(p.payload == [0x00, 0x00, 0x00, 0x06, 0x0D, 0x00, 0x00, 0x00, 0x01, 0x00])
    }
}
