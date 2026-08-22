import CoreGraphics

/// Presentation target geometry: aspect-fit to the layer, never below native frame size, unit-testable without a display link.
public struct PresentationPlan: Equatable, Sendable {
    /// Presentation target in backing pixels (aspect-fit, never below native).
    public let targetWidth: Int
    public let targetHeight: Int
    /// True when upscaling would add detail (target > frame in either dimension).
    public let upscaleBeneficial: Bool

    public init(frameWidth: Int, frameHeight: Int,
                boundsWidth: CGFloat, boundsHeight: CGFloat, contentsScale: CGFloat) {
        let backingWidth = boundsWidth * contentsScale
        let backingHeight = boundsHeight * contentsScale
        // Degenerate frame/layout: present at native size.
        guard frameWidth > 0, frameHeight > 0, backingWidth > 0, backingHeight > 0 else {
            targetWidth = max(frameWidth, 0)
            targetHeight = max(frameHeight, 0)
            upscaleBeneficial = false
            return
        }
        let factor = min(backingWidth / CGFloat(frameWidth), backingHeight / CGFloat(frameHeight))
        guard factor > 1 else {   // no upscale needed
            targetWidth = frameWidth
            targetHeight = frameHeight
            upscaleBeneficial = false
            return
        }
        targetWidth = Int((CGFloat(frameWidth) * factor).rounded())
        targetHeight = Int((CGFloat(frameHeight) * factor).rounded())
        upscaleBeneficial = targetWidth > frameWidth || targetHeight > frameHeight
    }
}
