import SwiftUI

extension View {
    /// "Back out of this screen" on the keyboard. macOS routes Escape through `onExitCommand`, which
    /// iOS does not have; there a hardware Escape arrives as an ordinary key press.
    @ViewBuilder func onEscapeKey(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        onKeyPress(.escape) { action(); return .handled }
        #endif
    }
}
