import Foundation
@testable import InputEngine

/// Records actuation intents (channel/split-handle/intensity) without GameController hardware.
final class RecordingActuator: DeviceActuator, @unchecked Sendable {
    enum Action: Equatable {
        case intensity(slot: Int, locality: HapticLocality, intensity: Float)
        case led(slot: Int, red: UInt8, green: UInt8, blue: UInt8)
        case adaptiveTrigger(slot: Int, side: TriggerSide, type: UInt8, effect: [UInt8])
    }

    private let lock = NSLock()
    private var recorded: [Action] = []
    var actions: [Action] { lock.lock(); defer { lock.unlock() }; return recorded }

    func setIntensity(slot: Int, locality: HapticLocality, intensity: Float) {
        append(.intensity(slot: slot, locality: locality, intensity: intensity))
    }
    func setLED(slot: Int, red: UInt8, green: UInt8, blue: UInt8) {
        append(.led(slot: slot, red: red, green: green, blue: blue))
    }
    func setAdaptiveTrigger(slot: Int, side: TriggerSide, type: UInt8, effect: [UInt8]) {
        append(.adaptiveTrigger(slot: slot, side: side, type: type, effect: effect))
    }
    private func append(_ action: Action) { lock.lock(); recorded.append(action); lock.unlock() }
}
