import UIKit
import CoreImage
import SwiftUI

/// The platform's bitmap type, so shared views can render decoded box art and generated QR codes
/// without naming `NSImage` or `UIImage`.
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}

extension PlatformImage {
    /// Decoded box art straight from the host's PNG/JPEG bytes; nil when the bytes aren't an image.
    static func decoded(from data: Data) -> PlatformImage? { UIImage(data: data) }

    static func rendered(_ ciImage: CIImage) -> PlatformImage {
        // Rasterize through a CIContext: a UIImage wrapping a CIImage has no CGImage backing, and
        // SwiftUI silently draws nothing for one.
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return UIImage()
        }
        return UIImage(cgImage: cgImage)
    }
}

extension View {
    /// iOS has no hover cursor to restyle for touch, and lets the system shape the pointer for a
    /// connected mouse, so this is deliberately inert.
    @ViewBuilder func linkPointerStyle(_ isLink: Bool) -> some View { self }
}
