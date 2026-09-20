import SwiftUI

extension View {
    /// A popover anchored low on a phone gets less height than its list; without a scroll view the
    /// first and last rows are simply cut off.
    func deckMenuScrolling() -> some View {
        ScrollView { self }.scrollBounceBehavior(.basedOnSize)
    }
}
