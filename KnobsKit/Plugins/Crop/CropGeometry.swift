import CoreGraphics
import Foundation

/// Crop and straighten math, shared by the plugin and the canvas tool.
/// Rects are normalized to the photo with a top-left origin, in the straightened frame: (0, 0, 1, 1)
/// is the whole photo at angle 0. Straightening turns the photo about its center.
public struct CropGeometry: Sendable, Equatable {
    /// Source size in pixels. Answers are normalized, so any scale of the same photo gives the same ones.
    public let size: CGSize
    /// Degrees; positive turns the photo clockwise.
    public let angle: Double

    /// The shortest side a crop may have, as a fraction of the photo's shorter side.
    public static let minimumSide = 0.02

    public init(size: CGSize, angle: Double) {
        self.size = size
        self.angle = angle
    }

    /// The straightened photo's bounding box in source pixels: what the crop tool shows.
    public var boundingSize: CGSize {
        let cosine = abs(self.cosine)
        let sine = abs(self.sine)
        return CGSize(
            width: width * cosine + height * sine,
            height: width * sine + height * cosine
        )
    }

    /// What the plugin renders: the requested rect with its edges in order, fitted to the ratio and kept
    /// inside the rotated photo by shrinking it only as far as it must, then sliding it in.
    public func effectiveRect(requested: CGRect, ratio: Double?) -> CGRect {
        var box = minimumSized(box(requested.standardized))
        if let ratio {
            box = fitted(box: box, ratio: ratio)
        }
        return rect(constrained(box))
    }

    /// True when every corner of the rect lies on the photo, within `tolerance` source pixels.
    public func contains(rect: CGRect, tolerance: Double = 1e-6) -> Bool {
        box(rect).corners.allSatisfy { corner in
            let axes = photoAxes(corner)
            return abs(axes.u) <= width / 2 + tolerance && abs(axes.v) <= height / 2 + tolerance
        }
    }

    // MARK: Tool operations

    /// Drags the whole rect; it slides along the photo's edge rather than stopping at it.
    public func moved(rect: CGRect, by delta: CGVector) -> CGRect {
        var box = box(rect)
        box.offset(x: delta.dx * width, y: delta.dy * height)
        return self.rect(constrained(box))
    }

    /// Drags one handle from `rect`, which must already be valid. With a ratio the opposite corner
    /// (or edge) stays put and the rect keeps its shape; it stops where it would leave the photo.
    public func resized(rect: CGRect, handle: CropHandle, by delta: CGVector, ratio: Double?) -> CGRect {
        let start = box(rect)
        let shortest = minimumPixels
        var target = start
        switch handle.horizontal {
        case -1: target.minX = min(start.minX + delta.dx * width, start.maxX - shortest)
        case 1: target.maxX = max(start.maxX + delta.dx * width, start.minX + shortest)
        default: break
        }
        switch handle.vertical {
        case -1: target.minY = min(start.minY + delta.dy * height, start.maxY - shortest)
        case 1: target.maxY = max(start.maxY + delta.dy * height, start.minY + shortest)
        default: break
        }
        guard let ratio else {
            // Free: move both edges, then let each axis carry on alone so a stopped corner slides.
            var result = advance(from: start, to: target)
            result = advance(from: result, to: Box(minX: target.minX, minY: result.minY, maxX: target.maxX, maxY: result.maxY))
            result = advance(from: result, to: Box(minX: result.minX, minY: target.minY, maxX: result.maxX, maxY: target.maxY))
            return self.rect(constrained(result))
        }
        var w = target.width
        var h = target.height
        switch (handle.horizontal, handle.vertical) {
        case (0, _): w = h * ratio
        case (_, 0): h = w / ratio
        default:
            if w / h > ratio { h = w / ratio } else { w = h * ratio }
        }
        let grow = max(1, shortest / min(w, h))
        w *= grow
        h *= grow
        let across = Self.anchored(start: start.minX, end: start.maxX, direction: handle.horizontal, length: w)
        let down = Self.anchored(start: start.minY, end: start.maxY, direction: handle.vertical, length: h)
        target = Box(minX: across.min, minY: down.min, maxX: across.max, maxY: down.max)
        return self.rect(constrained(advance(from: start, to: target)))
    }

    /// Turns a landscape crop portrait and back, about its center (Lightroom's X).
    public func swappedOrientation(_ rect: CGRect) -> CGRect {
        let box = box(rect)
        let center = box.center
        let swapped = Box(
            minX: center.x - box.height / 2,
            minY: center.y - box.width / 2,
            maxX: center.x + box.height / 2,
            maxY: center.y + box.width / 2
        )
        return self.rect(constrained(swapped))
    }

    /// The largest rect of `ratio` (width over height, in pixels) that fits, as near `center` as it can sit.
    public func largest(ratio: Double, around center: CGPoint) -> CGRect {
        let x = (center.x - 0.5) * width
        let y = (center.y - 0.5) * height
        let reach = (width + height) * 2
        let huge = Box(minX: x - reach * ratio, minY: y - reach, maxX: x + reach * ratio, maxY: y + reach)
        return rect(constrained(huge))
    }

    /// The angle after a drag from `start` to `end` around `pivot`, in view points with y down.
    public static func straightened(angle: Double, from start: CGPoint, to end: CGPoint, around pivot: CGPoint) -> Double {
        let before = atan2(start.y - pivot.y, start.x - pivot.x)
        let after = atan2(end.y - pivot.y, end.x - pivot.x)
        var delta = (after - before) * 180 / .pi
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return min(max(angle + delta, -45), 45)
    }

    // MARK: Mapping to the straightened photo's bounding box

    /// A crop point as a fraction of the bounding box, top-left origin. The box shares the crop frame's
    /// center and axes, so this is a scale about the center.
    public func boundingPoint(_ point: CGPoint) -> CGPoint {
        let bounds = boundingSize
        return CGPoint(
            x: (point.x - 0.5) * width / bounds.width + 0.5,
            y: (point.y - 0.5) * height / bounds.height + 0.5
        )
    }

    public func cropPoint(bounding point: CGPoint) -> CGPoint {
        let bounds = boundingSize
        return CGPoint(
            x: (point.x - 0.5) * bounds.width / width + 0.5,
            y: (point.y - 0.5) * bounds.height / height + 0.5
        )
    }

    // MARK: Internals

    /// A rect in source pixels, y down, measured from the photo's center.
    struct Box: Equatable {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double

        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
        var center: (x: Double, y: Double) { ((minX + maxX) / 2, (minY + maxY) / 2) }
        var corners: [(x: Double, y: Double)] { [(minX, minY), (maxX, minY), (minX, maxY), (maxX, maxY)] }

        mutating func offset(x: Double, y: Double) {
            minX += x
            maxX += x
            minY += y
            maxY += y
        }
    }

    private var width: Double { Double(size.width) }
    private var height: Double { Double(size.height) }
    private var cosine: Double { cos(angle * .pi / 180) }
    private var sine: Double { sin(angle * .pi / 180) }
    private var minimumPixels: Double { Self.minimumSide * min(width, height) }

    func box(_ rect: CGRect) -> Box {
        Box(
            minX: (rect.minX - 0.5) * width,
            minY: (rect.minY - 0.5) * height,
            maxX: (rect.maxX - 0.5) * width,
            maxY: (rect.maxY - 0.5) * height
        )
    }

    func rect(_ box: Box) -> CGRect {
        CGRect(x: box.minX / width + 0.5, y: box.minY / height + 0.5, width: box.width / width, height: box.height / height)
    }

    /// A straightened point in the unrotated photo's axes; it is on the photo when |u| ≤ w/2 and |v| ≤ h/2.
    private func photoAxes(_ point: (x: Double, y: Double)) -> (u: Double, v: Double) {
        (cosine * point.x + sine * point.y, -sine * point.x + cosine * point.y)
    }

    private func straightenedPoint(u: Double, v: Double) -> (x: Double, y: Double) {
        (cosine * u - sine * v, sine * u + cosine * v)
    }

    private func minimumSized(_ box: Box) -> Box {
        let shortest = minimumPixels
        let center = box.center
        let w = max(box.width, shortest)
        let h = max(box.height, shortest)
        return Box(minX: center.x - w / 2, minY: center.y - h / 2, maxX: center.x + w / 2, maxY: center.y + h / 2)
    }

    /// The largest rect of the ratio inside `box`, on the same center.
    private func fitted(box: Box, ratio: Double) -> Box {
        let center = box.center
        var w = box.width
        var h = box.height
        if w / h > ratio * (1 + 1e-9) {
            w = h * ratio
        } else if w / h < ratio * (1 - 1e-9) {
            h = w / ratio
        } else {
            return box
        }
        return Box(minX: center.x - w / 2, minY: center.y - h / 2, maxX: center.x + w / 2, maxY: center.y + h / 2)
    }

    /// Shrinks the box about its center only if it cannot fit even centered, then slides it onto the photo.
    private func constrained(_ box: Box) -> Box {
        let cosine = abs(self.cosine)
        let sine = abs(self.sine)
        var a = box.width / 2
        var b = box.height / 2
        let scale = min(1, (width / 2) / (a * cosine + b * sine), (height / 2) / (a * sine + b * cosine))
        a *= scale
        b *= scale
        // How far the center may stray along each of the photo's own axes.
        let slackU = max(0, width / 2 - a * cosine - b * sine)
        let slackV = max(0, height / 2 - a * sine - b * cosine)
        let axes = photoAxes(box.center)
        let center = straightenedPoint(u: min(max(axes.u, -slackU), slackU), v: min(max(axes.v, -slackV), slackV))
        return Box(minX: center.x - a, minY: center.y - b, maxX: center.x + a, maxY: center.y + b)
    }

    /// Moves `start` toward `target` until the first corner would leave the photo. Both are linear in
    /// the step, so each corner's limit is a division.
    private func advance(from start: Box, to target: Box) -> Box {
        var step = 1.0
        for (from, to) in zip(start.corners, target.corners) {
            let a = photoAxes(from)
            let b = photoAxes(to)
            step = min(step, Self.reach(start: a.u, change: b.u - a.u, bound: width / 2))
            step = min(step, Self.reach(start: a.v, change: b.v - a.v, bound: height / 2))
        }
        step = max(0, step)
        return Box(
            minX: start.minX + (target.minX - start.minX) * step,
            minY: start.minY + (target.minY - start.minY) * step,
            maxX: start.maxX + (target.maxX - start.maxX) * step,
            maxY: start.maxY + (target.maxY - start.maxY) * step
        )
    }

    private static func reach(start: Double, change: Double, bound: Double) -> Double {
        if change > 1e-12 { return (bound - start) / change }
        if change < -1e-12 { return (-bound - start) / change }
        return 1
    }

    /// One axis of a resized rect: pinned at the far edge, the near edge, or centered for the cross axis.
    private static func anchored(start: Double, end: Double, direction: Int, length: Double) -> (min: Double, max: Double) {
        switch direction {
        case -1: (end - length, end)
        case 1: (start, start + length)
        default: ((start + end) / 2 - length / 2, (start + end) / 2 + length / 2)
        }
    }
}

/// A grip on the crop rect. `horizontal` and `vertical` say which edges it moves: -1 the left or top, 1 the right or bottom.
public enum CropHandle: Sendable, Hashable, CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    public var horizontal: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .topRight, .right, .bottomRight: 1
        case .top, .bottom: 0
        }
    }

    public var vertical: Int {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .bottomLeft, .bottom, .bottomRight: 1
        case .left, .right: 0
        }
    }

    public var isCorner: Bool {
        horizontal != 0 && vertical != 0
    }
}
