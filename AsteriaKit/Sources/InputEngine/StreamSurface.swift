import AsteriaModel

/// App-shell seam for input-capture and cursor-mode side effects.
public protocol StreamSurface: AnyObject, Sendable {
    /// Apply input capture and the cursor behavior required by the active mouse mode.
    func applyInputState(active: Bool, mouseMode: MouseMode)
}
