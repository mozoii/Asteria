import GameStreamProtocol

/// Host-bound seam: the enqueue surface (keyboard, mouse, scroll, controller, battery, haptics).
public protocol InputSink: AnyObject, Sendable {
    func keyboard(keyCode: Int16, down: Bool, modifiers: UInt8, flags: UInt8)
    func mouseButton(_ button: UInt8, down: Bool)
    func mouseMoveRelative(deltaX: Int, deltaY: Int)
    func mouseMoveAbsolute(x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16)
    func scrollVertical(_ amount: Int)
    func scrollHorizontal(_ amount: Int)
    func controller(_ snapshot: ControllerSnapshot)
    func controllerArrival(index: UInt8, type: UInt8, supportedButtonFlags: UInt32, capabilities: UInt16)
    func controllerBattery(index: UInt8, state: UInt8, percentage: UInt8)
    func enableHaptics()
}

extension InputSender: InputSink {}
