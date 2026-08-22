/// App→engine seam for NSEvent-sourced keyboard/mouse (the reverse of `StreamSurface`); the live engine conforms.
public protocol LocalInputSink: Sendable {
    func feedKey(scancode: Int, pressed: Bool)
    func feedRelativePointer(deltaX: Double, deltaY: Double)
    func feedAbsolutePointer(viewX: Int, viewY: Int, viewWidth: Int, viewHeight: Int,
                             eventAgeNanos: UInt64)
    func feedMouseButton(_ button: LocalMouseButton, down: Bool)
    func feedScroll(preciseX: Double, preciseY: Double)
}

public enum LocalMouseButton: Sendable {
    case left, right, middle, extra1, extra2
}
