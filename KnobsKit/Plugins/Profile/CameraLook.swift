import Foundation

/// How a camera rendered a RAW: a color matrix and a tone curve applied to the neutral decode. Fitted to
/// the JPEG the camera embedded in the file when the photo loads; a fixed look stands in without one.
public struct CameraLook: Sendable, Hashable {
    public enum Origin: Sendable, Hashable {
        /// Fitted to the camera's embedded JPEG.
        case preview
        /// The file had no usable preview.
        case fallback
    }

    /// Knots sit every `step` stops of scene-linear value from `lowStop` to `highStop`.
    static let lowStop: Float = -12
    static let highStop: Float = 4
    static let step: Float = 0.25
    static let knotCount = Int((highStop - lowStop) / step) + 1
    static let identityMatrix: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    /// Display-linear output at each knot, rising until it holds at white. Below the first knot the curve
    /// runs straight to black.
    public let levels: [Float]
    /// Row-major 3×3 applied to scene-linear color before the curve. It keeps white and luminance.
    public let matrix: [Float]
    public let origin: Origin

    init(levels: [Float], matrix: [Float] = CameraLook.identityMatrix, origin: Origin) {
        self.levels = levels
        self.matrix = matrix
        self.origin = origin
    }

    static func stop(knot: Int) -> Float {
        lowStop + Float(knot) * step
    }

    /// Stands in when a RAW has no usable preview: about half a stop darker than the neutral decode
    /// through the midtones, with a shoulder that uses the decoder's headroom up to white.
    static let fallback: CameraLook = {
        let exposure = exp2(Float(-0.6))
        let pairs = stride(from: Float(-10), through: log2(0.6 / exposure), by: 0.25).map { stop in
            (exp2(stop), exposure * exp2(stop))
        }
        guard let levels = levels(pairs: pairs, white: RenderEngine.rawWhite) else {
            preconditionFailure("The fallback curve must fit")
        }
        return CameraLook(levels: levels, origin: .fallback)
    }()

    /// sRGB transfer curve, mirrored for negatives like the kernels' `knobs::to_gamma`.
    static func gamma(_ x: Float) -> Float {
        let a = abs(x)
        let y = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return x < 0 ? -y : y
    }

    static func linear(_ x: Float) -> Float {
        let a = abs(x)
        let y = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return x < 0 ? -y : y
    }
}

/// The curve sampled densely over the knots' range: the kernel's lookup row, and the CPU twin the fit uses.
struct ToneTable {
    static let width = 1024
    static let samplesPerStop = Float(width - 1) / (CameraLook.highStop - CameraLook.lowStop)

    /// Display-linear output at log2 value `lowStop + i / samplesPerStop`.
    let values: [Float]
    /// Slope of the straight run to black below the first sample.
    let toe: Float

    init(values: [Float], toe: Float) {
        self.values = values
        self.toe = toe
    }

    /// Monotone cubic through the knots in (stops, sRGB gamma), so the curve has no kinks and never wiggles.
    init(look: CameraLook) {
        let knots = look.levels.indices.map { index in
            CurvePoint(x: Double(CameraLook.stop(knot: index)), y: Double(CameraLook.gamma(look.levels[index])))
        }
        let stops = (0..<Self.width).map { Double(CameraLook.lowStop + Float($0) / Self.samplesPerStop) }
        let values = MonotoneCurve(points: knots).values(at: stops).map { CameraLook.linear(Float($0)) }
        self.init(values: values, toe: values[0] / exp2(CameraLook.lowStop))
    }

    func callAsFunction(_ x: Float) -> Float {
        read { $0(x) }
    }

    /// The scene value the curve takes to `y`; nil at or above the curve's top.
    func inverse(_ y: Float) -> Float? {
        read { $0.inverse(y) }
    }

    func read<Result>(_ body: (ToneReader) -> Result) -> Result {
        values.withUnsafeBufferPointer { body(ToneReader(values: $0, toe: toe)) }
    }
}

/// A `ToneTable` over a raw buffer, for per-pixel loops: checked array access is slow in debug builds.
struct ToneReader {
    let values: UnsafeBufferPointer<Float>
    let toe: Float

    func callAsFunction(_ x: Float) -> Float {
        guard x > 0 else { return x * toe }
        let position = (log2(x) - CameraLook.lowStop) * ToneTable.samplesPerStop
        if position <= 0 { return x * toe }
        let last = values.count - 1
        if position >= Float(last) { return values[last] }
        let index = Int(position)
        let fraction = position - Float(index)
        return values[index] + (values[index + 1] - values[index]) * fraction
    }

    func inverse(_ y: Float) -> Float? {
        guard y < values[values.count - 1] else { return nil }
        guard y > values[0] else { return y / toe }
        var low = 0
        var high = values.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if values[middle] <= y { low = middle } else { high = middle }
        }
        let fraction = (y - values[low]) / max(values[high] - values[low], 1e-12)
        return exp2(CameraLook.lowStop + (Float(low) + fraction) / ToneTable.samplesPerStop)
    }

    /// The kernel's math on the CPU: the matrix (row-major), then the curve on the brightest and darkest
    /// channel with the middle one kept at its relative place between them.
    func render(red: Float, green: Float, blue: Float, matrix m: UnsafeBufferPointer<Float>) -> (Float, Float, Float) {
        let r = m[0] * red + m[1] * green + m[2] * blue
        let g = m[3] * red + m[4] * green + m[5] * blue
        let b = m[6] * red + m[7] * green + m[8] * blue
        let high = max(r, g, b)
        let low = min(r, g, b)
        let newLow = self(low)
        let span = high - low
        guard span > 1e-6 else { return (newLow, newLow, newLow) }
        let scale = (self(high) - newLow) / span
        return (newLow + (r - low) * scale, newLow + (g - low) * scale, newLow + (b - low) * scale)
    }
}
