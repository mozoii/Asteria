import SwiftUI

extension View {
    /// Release notes own the whole screen on a phone. A sheet would frame the Mac-sized card in
    /// grey margins above and below it, which reads as a layout bug rather than a card.
    func releaseNotesPresentation(isPresented: Binding<Bool>,
                                  onDismiss: (() -> Void)? = nil) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) { WhatsNewSheet() }
    }

    func releaseNotesFrame() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
