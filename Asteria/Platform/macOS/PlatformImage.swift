import AppKit
import CoreImage
import SwiftUI

/// The platform's bitmap type, so shared views can render decoded box art and generated QR codes
/// without naming `NSImage` or `UIImage`.
typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}

extension PlatformImage {
    /// Decoded box art straight from the host's PNG/JPEG bytes; nil when the bytes aren't an image.
    static func decoded(from data: Data) -> PlatformImage? { NSImage(data: data) }

    static func rendered(_ ciImage: CIImage) -> PlatformImage {
        let rep = NSCIImageRep(ciImage: ciImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

extension View {
    /// The link cursor on hover, for text that acts as a button.
    @ViewBuilder func linkPointerStyle(_ isLink: Bool) -> some View {
        pointerStyle(isLink ? .link : .default)
    }
}
