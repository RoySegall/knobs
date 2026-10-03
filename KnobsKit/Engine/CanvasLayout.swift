import CoreGraphics

/// Where the canvas draws an image: fitted inside the padded drawable and centered on whole pixels.
/// The canvas draws with it and tool overlays map through it, so both agree on every point.
public struct CanvasLayout: Sendable, Equatable {
    /// Drawable pixels per image pixel.
    public let scale: CGFloat
    /// The drawn image in drawable pixels, Core Image's bottom-left origin.
    public let frame: CGRect
    public let drawableSize: CGSize

    /// Within 1% of a fit the image is drawn 1:1, so the usual frame is a pure translate with no resampling.
    public static func fit(imageSize: CGSize, drawableSize: CGSize, padding: CGFloat) -> CanvasLayout {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CanvasLayout(scale: 1, frame: .zero, drawableSize: drawableSize)
        }
        var scale = min(
            (drawableSize.width - padding * 2) / imageSize.width,
            (drawableSize.height - padding * 2) / imageSize.height
        )
        if abs(scale - 1) <= 0.01 || scale <= 0 {
            scale = 1
        }
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: ((drawableSize.width - size.width) / 2).rounded(),
            y: ((drawableSize.height - size.height) / 2).rounded()
        )
        return CanvasLayout(scale: scale, frame: CGRect(origin: origin, size: size), drawableSize: drawableSize)
    }

    /// The drawn image in view points, top-left origin.
    public func viewFrame(pixelsPerPoint: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX / pixelsPerPoint,
            y: (drawableSize.height - frame.maxY) / pixelsPerPoint,
            width: frame.width / pixelsPerPoint,
            height: frame.height / pixelsPerPoint
        )
    }

    /// A point given as a fraction of the image, top-left origin, in view points.
    public func viewPoint(unit: CGPoint, pixelsPerPoint: CGFloat) -> CGPoint {
        let view = viewFrame(pixelsPerPoint: pixelsPerPoint)
        return CGPoint(x: view.minX + unit.x * view.width, y: view.minY + unit.y * view.height)
    }

    /// The inverse of `viewPoint`; points off the image give fractions outside 0...1.
    public func unitPoint(view point: CGPoint, pixelsPerPoint: CGFloat) -> CGPoint {
        let view = viewFrame(pixelsPerPoint: pixelsPerPoint)
        guard view.width > 0, view.height > 0 else { return .zero }
        return CGPoint(x: (point.x - view.minX) / view.width, y: (point.y - view.minY) / view.height)
    }
}
