import Accelerate
import CoreImage

/// The whole tone curve per channel, sampled on 0...1 in gamma space, plus the end values and tangents
/// the kernel extends along for pixels outside 0...1.
struct ToneCurveLUT {
    static let width = 1024
    private static let inputs = (0..<width).map { Double($0) / Double(width - 1) }

    /// RGBA floats, one texel per sample.
    let samples: [Float]
    let low: SIMD3<Double>
    let lowSlope: SIMD3<Double>
    let high: SIMD3<Double>
    let highSlope: SIMD3<Double>

    /// Lightroom's order: parametric, then the RGB point curve, then each channel's own curve.
    init(parametric: MonotoneCurve, rgb: MonotoneCurve, channels: [MonotoneCurve]) {
        let toned = parametric.isIdentity ? Self.inputs : parametric.values(at: Self.inputs)
        let mixed = rgb.isIdentity ? toned : rgb.values(at: toned)

        // Strided convert into the RGBA row; a per-element Swift loop costs most of a frame in debug builds.
        var samples = [Float](repeating: 1, count: Self.width * 4)
        samples.withUnsafeMutableBufferPointer { samples in
            for (offset, channel) in channels.enumerated() {
                let outputs = channel.isIdentity ? mixed : channel.values(at: mixed)
                vDSP_vdpsp(outputs, 1, samples.baseAddress! + offset, 4, vDSP_Length(Self.width))
            }
        }
        self.samples = samples

        // Chain rule through the three curves. A falling end (an inverted curve) holds flat instead.
        func end(at x: Double) -> (value: SIMD3<Double>, slope: SIMD3<Double>) {
            let toned = parametric.value(at: x)
            let mixed = rgb.value(at: toned)
            let slope = parametric.slope(at: x) * rgb.slope(at: toned)
            return (
                SIMD3(channels.map { $0.value(at: mixed) }),
                SIMD3(channels.map { max(0, slope * $0.slope(at: mixed)) })
            )
        }
        (low, lowSlope) = end(at: 0)
        (high, highSlope) = end(at: 1)
    }

    /// One row, uncolor-managed so the kernel reads the samples exactly as written.
    var image: CIImage {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(
            bitmapData: data,
            bytesPerRow: Self.width * 16,
            size: CGSize(width: Self.width, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
    }
}
