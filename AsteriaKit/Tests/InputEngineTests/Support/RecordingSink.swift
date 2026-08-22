import Foundation
import GameStreamProtocol
import InputEngine

/// Records host-bound events in order; production adapter is `InputSender`.
final class RecordingSink: InputSink, @unchecked Sendable {
    enum Event: Equatable {
        case keyboard(keyCode: Int16, down: Bool, modifiers: UInt8, flags: UInt8)
        case mouseButton(UInt8, down: Bool)
        case mouseMoveRelative(dx: Int, dy: Int)
        case mouseMoveAbsolute(x: Int16, y: Int16, refW: Int16, refH: Int16)
        case scrollVertical(Int)
        case scrollHorizontal(Int)
        case controller(ControllerSnapshot)
        case controllerArrival(index: UInt8, type: UInt8, supported: UInt32, capabilities: UInt16)
        case controllerBattery(index: UInt8, state: UInt8, percentage: UInt8)
        case enableHaptics
    }

    private let lock = NSLock()
    private var recorded: [Event] = []

    var events: [Event] { lock.lock(); defer { lock.unlock() }; return recorded }
    func reset() { lock.lock(); recorded.removeAll(); lock.unlock() }

    private func record(_ event: Event) { lock.lock(); recorded.append(event); lock.unlock() }

    func keyboard(keyCode: Int16, down: Bool, modifiers: UInt8, flags: UInt8) {
        record(.keyboard(keyCode: keyCode, down: down, modifiers: modifiers, flags: flags))
    }
    func mouseButton(_ button: UInt8, down: Bool) { record(.mouseButton(button, down: down)) }
    func mouseMoveRelative(deltaX: Int, deltaY: Int) { record(.mouseMoveRelative(dx: deltaX, dy: deltaY)) }
    func mouseMoveAbsolute(x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16) {
        record(.mouseMoveAbsolute(x: x, y: y, refW: referenceWidth, refH: referenceHeight))
    }
    func scrollVertical(_ amount: Int) { record(.scrollVertical(amount)) }
    func scrollHorizontal(_ amount: Int) { record(.scrollHorizontal(amount)) }
    func controller(_ snapshot: ControllerSnapshot) { record(.controller(snapshot)) }
    func controllerArrival(index: UInt8, type: UInt8, supportedButtonFlags: UInt32, capabilities: UInt16) {
        record(.controllerArrival(index: index, type: type, supported: supportedButtonFlags, capabilities: capabilities))
    }
    func controllerBattery(index: UInt8, state: UInt8, percentage: UInt8) {
        record(.controllerBattery(index: index, state: state, percentage: percentage))
    }
    func enableHaptics() { record(.enableHaptics) }
}
