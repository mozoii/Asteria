import Testing
import GameStreamProtocol
import AsteriaModel
@testable import InputEngine

@Suite("InputCore actuation decisions")
struct InputActuationTests {
    private func makeCore(sink: RecordingSink, actuator: DeviceActuator) -> InputCore {
        let core = InputCore(sink: sink, surface: nil, resolver: KeybindingResolver(.defaults), mouseMode: .game,
                             swapFaceButtons: false, swapMouseButtons: false,
                             swapWinAltKeys: false, systemKeyCaptureActive: false, streamWidth: 0,
                             streamHeight: 0, onCommand: { _ in })
        core.setActuator(actuator)
        return core
    }

    @Test("host messages are tallied by kind")
    func tally() {
        let core = makeCore(sink: RecordingSink(), actuator: RecordingActuator())
        core.handleHostMessage(.rumble(controllerNumber: 0, lowFreq: 1, highFreq: 1))
        core.handleHostMessage(.setControllerLED(controllerNumber: 0, red: 0, green: 0, blue: 0))
        core.handleHostMessage(.setMotionEventState(controllerNumber: 0, reportRateHz: 0, motionType: 0))
        core.handleHostMessage(.setHdrMode(enabled: true))
        core.handleHostMessage(.termination(errorCode: 0))
        core.handleHostMessage(.unknown(type: 0x9999, payload: []))

        var expected = InboundControlCounts()
        expected.rumble = 1; expected.led = 1; expected.motion = 1
        expected.hdr = 1; expected.termination = 1; expected.unknown = 1
        #expect(core.inboundCounts == expected)
    }

    @Test("a termination message yields its code and is still counted")
    func terminationYieldsCodeAndCounts() {
        var codes: [UInt32] = []
        let core = InputCore(sink: RecordingSink(), surface: nil, resolver: KeybindingResolver(.defaults),
                             mouseMode: .game, swapFaceButtons: false, swapMouseButtons: false,
                             swapWinAltKeys: false, systemKeyCaptureActive: false, streamWidth: 0,
                             streamHeight: 0, onCommand: { _ in }, onTermination: { codes.append($0) })
        core.setActuator(RecordingActuator())

        core.handleHostMessage(.termination(errorCode: 0x00010203))

        #expect(codes == [0x00010203])
        #expect(core.inboundCounts.termination == 1)
    }

    @Test("split-handle controllers route the two rumble motors to left/right handles")
    func rumbleSplit() {
        let actuator = RecordingActuator()
        let core = makeCore(sink: RecordingSink(), actuator: actuator)
        core.gamepadArrival(GamepadArrival(index: 0, type: 0, supportedButtonFlags: 0, capabilities: 0,
                                           battery: nil, supportsSplitHandles: true))
        core.handleHostMessage(.rumble(controllerNumber: 0, lowFreq: 100, highFreq: 200))
        #expect(actuator.actions == [
            .intensity(slot: 0, locality: .leftHandle, intensity: HapticCurve.motorIntensity(100)),
            .intensity(slot: 0, locality: .rightHandle, intensity: HapticCurve.motorIntensity(200)),
        ])
    }

    @Test("controllers without split handles blend both motors into the combined channel")
    func rumbleCombined() {
        let actuator = RecordingActuator()
        let core = makeCore(sink: RecordingSink(), actuator: actuator)
        // No arrival → splitHandles defaults false.
        core.handleHostMessage(.rumble(controllerNumber: 1, lowFreq: 100, highFreq: 200))
        #expect(actuator.actions == [
            .intensity(slot: 1, locality: .combined, intensity: HapticCurve.combinedIntensity(low: 100, high: 200)),
        ])
    }

    @Test("trigger rumble drives both trigger channels")
    func triggerRumble() {
        let actuator = RecordingActuator()
        let core = makeCore(sink: RecordingSink(), actuator: actuator)
        core.handleHostMessage(.rumbleTriggers(controllerNumber: 0, leftTrigger: 300, rightTrigger: 400))
        #expect(actuator.actions == [
            .intensity(slot: 0, locality: .leftTrigger, intensity: HapticCurve.motorIntensity(300)),
            .intensity(slot: 0, locality: .rightTrigger, intensity: HapticCurve.motorIntensity(400)),
        ])
    }

    @Test("LED and adaptive-trigger messages forward to the actuator")
    func ledAndTriggers() {
        let actuator = RecordingActuator()
        let core = makeCore(sink: RecordingSink(), actuator: actuator)
        let left = [UInt8](repeating: 7, count: 10)
        let right = [UInt8](repeating: 9, count: 10)
        core.handleHostMessage(.setControllerLED(controllerNumber: 2, red: 10, green: 20, blue: 30))
        core.handleHostMessage(.setAdaptiveTriggers(controllerNumber: 0, eventFlags: 0, typeLeft: 1,
                                                    typeRight: 2, left: left, right: right))
        #expect(actuator.actions == [
            .led(slot: 2, red: 10, green: 20, blue: 30),
            .adaptiveTrigger(slot: 0, side: .left, type: 1, effect: left),
            .adaptiveTrigger(slot: 0, side: .right, type: 2, effect: right),
        ])
    }

    @Test("arrival announces identity + battery to the host and stores the split capability")
    func arrivalEmitsAndStoresSplit() {
        let sink = RecordingSink()
        let actuator = RecordingActuator()
        let core = makeCore(sink: sink, actuator: actuator)
        core.gamepadArrival(GamepadArrival(index: 3, type: ControllerType.xbox, supportedButtonFlags: 0xFF,
                                           capabilities: 0x0F,
                                           battery: BatterySample(state: BatteryState.charging, percentage: 80),
                                           supportsSplitHandles: true))
        #expect(sink.events == [
            .controllerArrival(index: 3, type: ControllerType.xbox, supported: 0xFF, capabilities: 0x0F),
            .controllerBattery(index: 3, state: BatteryState.charging, percentage: 80),
        ])
        // The stored split capability routes this slot's rumble to the handles.
        core.handleHostMessage(.rumble(controllerNumber: 3, lowFreq: 10, highFreq: 20))
        #expect(actuator.actions == [
            .intensity(slot: 3, locality: .leftHandle, intensity: HapticCurve.motorIntensity(10)),
            .intensity(slot: 3, locality: .rightHandle, intensity: HapticCurve.motorIntensity(20)),
        ])
    }

    @Test("arrival without a battery emits only the arrival announcement")
    func arrivalNoBattery() {
        let sink = RecordingSink()
        let core = makeCore(sink: sink, actuator: RecordingActuator())
        core.gamepadArrival(GamepadArrival(index: 0, type: 0, supportedButtonFlags: 0, capabilities: 0,
                                           battery: nil, supportsSplitHandles: false))
        #expect(sink.events == [.controllerArrival(index: 0, type: 0, supported: 0, capabilities: 0)])
    }

    @Test("a host that goes silent mid-rumble is forced to zero after the watchdog timeout")
    func watchdogExpiresStuckRumble() {
        var clock: UInt64 = 0
        let actuator = RecordingActuator()
        let core = InputCore(sink: RecordingSink(), surface: nil, resolver: KeybindingResolver(.defaults),
                             mouseMode: .game, swapFaceButtons: false, swapMouseButtons: false,
                             swapWinAltKeys: false, systemKeyCaptureActive: false, streamWidth: 0,
                             streamHeight: 0, now: { clock }, onCommand: { _ in })
        core.setActuator(actuator)
        core.gamepadArrival(GamepadArrival(index: 0, type: 0, supportedButtonFlags: 0, capabilities: 0,
                                           battery: nil, supportsSplitHandles: true))
        core.handleHostMessage(.rumble(controllerNumber: 0, lowFreq: 100, highFreq: 0))

        clock = 1_000_000_000                            // 1s — under the 1.5s timeout
        core.expireStaleRumble()
        clock = 3_000_000_000                            // 3s — past the timeout
        core.expireStaleRumble()

        #expect(actuator.actions == [
            .intensity(slot: 0, locality: .leftHandle, intensity: HapticCurve.motorIntensity(100)),
            .intensity(slot: 0, locality: .rightHandle, intensity: HapticCurve.motorIntensity(0)),
            .intensity(slot: 0, locality: .leftHandle, intensity: 0),   // forced off; rightHandle was already idle
        ])
    }

    @Test("an explicit zero from the host disarms the watchdog")
    func watchdogNotArmedByZero() {
        var clock: UInt64 = 0
        let actuator = RecordingActuator()
        let core = InputCore(sink: RecordingSink(), surface: nil, resolver: KeybindingResolver(.defaults),
                             mouseMode: .game, swapFaceButtons: false, swapMouseButtons: false,
                             swapWinAltKeys: false, systemKeyCaptureActive: false, streamWidth: 0,
                             streamHeight: 0, now: { clock }, onCommand: { _ in })
        core.setActuator(actuator)
        core.gamepadArrival(GamepadArrival(index: 0, type: 0, supportedButtonFlags: 0, capabilities: 0,
                                           battery: nil, supportsSplitHandles: true))
        core.handleHostMessage(.rumble(controllerNumber: 0, lowFreq: 100, highFreq: 0))
        core.handleHostMessage(.rumble(controllerNumber: 0, lowFreq: 0, highFreq: 0))   // host stops it

        clock = 3_000_000_000
        core.expireStaleRumble()
        // Four drive actions total (two rumbles x two handles); no watchdog-forced zero, the explicit zero disarmed it.
        #expect(actuator.actions.count == 4)
        #expect(actuator.actions.last == .intensity(slot: 0, locality: .rightHandle, intensity: 0))
    }

    @Test("disconnect clears the stored split capability")
    func disconnectClearsSplit() {
        let actuator = RecordingActuator()
        let core = makeCore(sink: RecordingSink(), actuator: actuator)
        core.gamepadArrival(GamepadArrival(index: 0, type: 0, supportedButtonFlags: 0, capabilities: 0,
                                           battery: nil, supportsSplitHandles: true))
        core.gamepadDisconnected(index: 0)
        core.handleHostMessage(.rumble(controllerNumber: 0, lowFreq: 100, highFreq: 200))
        // After disconnect the slot is no longer split → combined routing.
        #expect(actuator.actions == [
            .intensity(slot: 0, locality: .combined, intensity: HapticCurve.combinedIntensity(low: 100, high: 200)),
        ])
    }
}
