import SwiftUI

extension View {
    /// A Mac popover sizes itself to the whole list, so it needs no scroll view.
    func deckMenuScrolling() -> some View { self }
}
