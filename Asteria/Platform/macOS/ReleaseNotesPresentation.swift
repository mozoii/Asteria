import SwiftUI

extension View {
    /// A sheet sized to the card: the Mac window is far bigger than release notes need.
    func releaseNotesPresentation(isPresented: Binding<Bool>,
                                  onDismiss: (() -> Void)? = nil) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { WhatsNewSheet() }
    }

    func releaseNotesFrame() -> some View {
        frame(maxWidth: 480, maxHeight: 620)
    }
}
