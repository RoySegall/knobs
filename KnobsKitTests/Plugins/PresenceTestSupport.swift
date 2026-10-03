import CoreImage
@testable import KnobsKit

/// Synthetic scenes and measurements for the texture, clarity and dehaze tests.
enum PresenceScene {
    /// sRGB decode, so scenes can be described in the encoded values a photographer reads.
    static func linear(_ encoded: Float) -> Float {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ linear: Float) -> Float {
        let value = max(linear, 0)
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    /// Linear RGB from a closure of (x, y), y counted from the top row.
    static func make(width: Int, height: Int, pixel: (Int, Int) -> SIMD3<Float>) -> CIImage {
        var floats = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = pixel(x, y)
                let index = (y * width + x) * 4
                floats[index] = rgb.x
                floats[index + 1] = rgb.y
                floats[index + 2] = rgb.z
            }
        }
        return TestImages.image(floats: floats, width: width, height: height)
    }

    /// Gray whose encoded value is `encoded`, as linear RGB.
    static func gray(_ encoded: Float) -> SIMD3<Float> {
        SIMD3(repeating: linear(encoded))
    }

    /// Deterministic value in 0..<1 per pixel.
    static func noise(x: Int, y: Int, seed: UInt64 = 1) -> Float {
        var h = UInt64(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663) &+ seed &* 83_492_791
        h = (h ^ (h >> 33)) &* 0xff51afd7ed558ccd
        h = (h ^ (h >> 33)) &* 0xc4ceb9fe1a85ec53
        h ^= h >> 33
        return Float(h & 0xFFFFFF) / Float(0x1000000)
    }

    static func context(for image: CIImage, scale: Double = 1) -> RenderContext {
        let size = CGSize(width: image.extent.width / scale, height: image.extent.height / scale)
        return RenderContext(scale: scale, fullSize: size, source: .bitmap)
    }

    static func apply(_ plugin: some KnobPlugin, amount: Double, to image: CIImage, scale: Double = 1) -> CIImage {
        let values = KnobValues(params: plugin.params, stored: ["amount": .number(amount)])
        return plugin.apply(image: image, values: values, context: context(for: image, scale: scale))
    }
}

/// Pixel grid read back from an image, row-major from the top.
struct PresencePixels {
    let width: Int
    let height: Int
    let rgba: [Float]

    init(_ image: CIImage) {
        width = Int(image.extent.width)
        height = Int(image.extent.height)
        rgba = Pixels.read(image)
    }

    func rgb(x: Int, y: Int) -> SIMD3<Float> {
        let index = (y * width + x) * 4
        return SIMD3(rgba[index], rgba[index + 1], rgba[index + 2])
    }

    /// sRGB-encoded Rec. 709 luminance.
    func luma(x: Int, y: Int) -> Float {
        let c = rgb(x: x, y: y)
        return PresenceScene.encoded(0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z)
    }

    func lumas(x: Range<Int>, y: Range<Int>) -> [Float] {
        y.flatMap { row in x.map { luma(x: $0, y: row) } }
    }

    static func mean(_ values: [Float]) -> Float {
        values.reduce(0, +) / Float(max(values.count, 1))
    }

    static func deviation(_ values: [Float]) -> Float {
        let mean = mean(values)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(max(values.count, 1))).squareRoot()
    }
}
