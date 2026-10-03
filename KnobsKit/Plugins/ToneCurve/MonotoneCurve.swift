import Foundation

/// Monotone cubic (Fritsch–Carlson) through a curve's points. Each segment stays between its two
/// points, so a curve never overshoots or wiggles. The plugin and the curve editor share it.
public struct MonotoneCurve: Sendable {
    /// Sorted by x, one point per x.
    public let points: [CurvePoint]
    /// Every point on the diagonal from 0 to 1, so the curve is y = x there.
    public let isIdentity: Bool
    private let tangents: [Double]

    public init(points input: [CurvePoint]) {
        var points: [CurvePoint] = []
        for point in input.filter({ $0.x.isFinite && $0.y.isFinite }).sorted(by: { $0.x < $1.x }) {
            // Two points at one x would divide by zero; the later one wins.
            if let last = points.last, point.x - last.x < 1e-9 {
                points[points.count - 1] = point
            } else {
                points.append(point)
            }
        }
        let sorted = points.isEmpty ? CurvePoint.identity : points
        self.init(sorted: sorted, tangents: Self.tangents(points: sorted))
    }

    /// Hermite through sorted points with the given tangents. The caller keeps it monotone.
    init(sorted points: [CurvePoint], tangents: [Double]) {
        self.points = points
        self.tangents = tangents
        isIdentity = points.first?.x == 0 && points.last?.x == 1
            && points.allSatisfy { $0.x == $0.y } && tangents.allSatisfy { $0 == 1 }
    }

    /// Flat beyond the first and last point.
    public func value(at x: Double) -> Double {
        values(at: [x])[0]
    }

    /// `value(at:)` for many xs at once, walking the segments while xs ascend. The plugin calls this on
    /// every drag frame, so it runs on raw buffers: checked array access is slow in debug builds.
    public func values(at xs: [Double]) -> [Double] {
        var output = [Double](repeating: 0, count: xs.count)
        points.withUnsafeBufferPointer { points in
            tangents.withUnsafeBufferPointer { tangents in
                xs.withUnsafeBufferPointer { xs in
                    output.withUnsafeMutableBufferPointer { output in
                        Self.evaluate(xs: xs, into: output, points: points, tangents: tangents)
                    }
                }
            }
        }
        return output
    }

    private static func evaluate(
        xs: UnsafeBufferPointer<Double>,
        into output: UnsafeMutableBufferPointer<Double>,
        points: UnsafeBufferPointer<CurvePoint>,
        tangents: UnsafeBufferPointer<Double>
    ) {
        let first = points[0]
        let last = points[points.count - 1]
        var index = 0
        for position in xs.indices {
            let x = xs[position]
            if x <= first.x {
                output[position] = first.y
                continue
            }
            if x >= last.x {
                output[position] = last.y
                continue
            }
            if x < points[index].x || x >= points[index + 1].x {
                index = segment(containing: x, points: points)
            }
            let start = points[index]
            let end = points[index + 1]
            let width = end.x - start.x
            let s = (x - start.x) / width
            let s2 = s * s
            let s3 = s2 * s
            output[position] = (2 * s3 - 3 * s2 + 1) * start.y
                + (s3 - 2 * s2 + s) * width * tangents[index]
                + (-2 * s3 + 3 * s2) * end.y
                + (s3 - s2) * width * tangents[index + 1]
        }
    }

    /// The derivative, with the end tangent exactly at an end point and zero on the flat parts beyond.
    public func slope(at x: Double) -> Double {
        guard let first = points.first, let last = points.last, points.count > 1 else { return 0 }
        if x == first.x { return tangents[0] }
        if x == last.x { return tangents[tangents.count - 1] }
        if x < first.x || x > last.x { return 0 }
        let index = points.withUnsafeBufferPointer { Self.segment(containing: x, points: $0) }
        let start = points[index]
        let end = points[index + 1]
        let width = end.x - start.x
        let s = (x - start.x) / width
        let s2 = s * s
        return (6 * s2 - 6 * s) * (start.y - end.y) / width
            + (3 * s2 - 4 * s + 1) * tangents[index]
            + (3 * s2 - 2 * s) * tangents[index + 1]
    }

    /// Index of the segment whose start is the last point at or before x.
    private static func segment(containing x: Double, points: UnsafeBufferPointer<CurvePoint>) -> Int {
        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].x <= x { low = middle } else { high = middle }
        }
        return low
    }

    private static func tangents(points: [CurvePoint]) -> [Double] {
        let count = points.count
        guard count > 1 else { return [0] }
        let widths = (0..<count - 1).map { points[$0 + 1].x - points[$0].x }
        let secants = (0..<count - 1).map { (points[$0 + 1].y - points[$0].y) / widths[$0] }
        guard count > 2 else { return [secants[0], secants[0]] }

        var tangents = [Double](repeating: 0, count: count)
        for index in 1..<count - 1 {
            let before = secants[index - 1]
            let after = secants[index]
            tangents[index] = before * after > 0 ? (before + after) / 2 : 0
        }
        tangents[0] = endTangent(near: widths[0], far: widths[1], nearSecant: secants[0], farSecant: secants[1])
        tangents[count - 1] = endTangent(
            near: widths[count - 2],
            far: widths[count - 3],
            nearSecant: secants[count - 2],
            farSecant: secants[count - 3]
        )

        // Fritsch–Carlson: flat segments stay flat, and steep tangents are scaled into the monotone region.
        for index in 0..<count - 1 {
            let secant = secants[index]
            if secant == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let alpha = tangents[index] / secant
            let beta = tangents[index + 1] / secant
            let length = alpha * alpha + beta * beta
            if length > 9 {
                let tau = 3 / length.squareRoot()
                tangents[index] = tau * alpha * secant
                tangents[index + 1] = tau * beta * secant
            }
        }
        return tangents
    }

    /// Three-point end estimate (as in PCHIP), so S-curves get a natural toe instead of a straight end.
    private static func endTangent(near: Double, far: Double, nearSecant: Double, farSecant: Double) -> Double {
        let tangent = ((2 * near + far) * nearSecant - near * farSecant) / (near + far)
        if tangent * nearSecant <= 0 {
            return 0
        }
        if nearSecant * farSecant < 0, abs(tangent) > abs(3 * nearSecant) {
            return 3 * nearSecant
        }
        return tangent
    }
}
