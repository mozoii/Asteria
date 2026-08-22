import Foundation

public enum AbsoluteMouse {
    public static func videoRect(streamWidth: Int, streamHeight: Int,
                                 viewWidth: Int, viewHeight: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        var x = 0, y = 0, w = viewWidth, h = viewHeight
        let dstH = Int(ceil(Double(viewWidth) * Double(streamHeight) / Double(streamWidth)))
        let dstW = Int(ceil(Double(viewHeight) * Double(streamWidth) / Double(streamHeight)))
        if dstH > viewHeight {
            x += (viewWidth - dstW) / 2
            w = dstW
        } else {
            y += (viewHeight - dstH) / 2
            h = dstH
        }
        return (x, y, w, h)
    }

    public static func map(pointX: Int, pointY: Int, streamWidth: Int, streamHeight: Int,
                           viewWidth: Int, viewHeight: Int) -> (x: Int16, y: Int16, refW: Int16, refH: Int16)? {
        let rect = videoRect(streamWidth: streamWidth, streamHeight: streamHeight,
                             viewWidth: viewWidth, viewHeight: viewHeight)
        guard rect.w > 0, rect.h > 0 else { return nil }
        let cx = min(max(pointX - rect.x, 0), rect.w - 1)
        let cy = min(max(pointY - rect.y, 0), rect.h - 1)
        return (Int16(clamping: cx), Int16(clamping: cy), Int16(clamping: rect.w), Int16(clamping: rect.h))
    }
}
