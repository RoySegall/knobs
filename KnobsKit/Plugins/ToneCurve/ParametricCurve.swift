import Foundation

/// Lightroom's parametric curve: each slider lifts or lowers the centre of its tonal region, and the
/// offset eases to its neighbours' with zero slope, so a slider never moves tones outside its neighbours.
public enum ParametricCurve {
    /// Shadow, midtone and highlight splits in gamma space, Lightroom's defaults.
    public static let splits = [0.25, 0.5, 0.75]
    /// Share of a region's width a full slider moves its centre. At 0.3 the slope never drops below 0.1.
    static let strength = 0.3

    /// Slider values are -100...100.
    public static func curve(shadows: Double, darks: Double, lights: Double, highlights: Double) -> MonotoneCurve {
        let edges = [0] + splits + [1]
        let amounts = [shadows, darks, lights, highlights]
        let centres = amounts.indices.map { region in
            let width = edges[region + 1] - edges[region]
            let centre = (edges[region] + edges[region + 1]) / 2
            return CurvePoint(x: centre, y: centre + strength * width * amounts[region] / 100)
        }
        let points = [CurvePoint(x: 0, y: 0)] + centres + [CurvePoint(x: 1, y: 1)]
        // Tangent 1 everywhere: the line y = x plus a smoothstep between neighbouring offsets.
        return MonotoneCurve(sorted: points, tangents: Array(repeating: 1, count: points.count))
    }
}
