import CoreImage
@testable import KnobsKit

enum TestImages {
    static let width = 96
    static let height = 64
    static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// Hue sweeps left to right, brightness rises bottom to top past 1.0, and a 2px checker adds fine detail.
    static func detail() -> CIImage {
        var floats = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = 0.03 + 1.1 * Double(y) / Double(height - 1)
                let rgb = hsv(hue: Double(x) / Double(width), saturation: 0.7, value: value)
                let checker: Double = (x / 2 + y / 2) % 2 == 0 ? 1.06 : 0.94
                let index = (y * width + x) * 4
                floats[index] = Float(rgb.red * checker)
                floats[index + 1] = Float(rgb.green * checker)
                floats[index + 2] = Float(rgb.blue * checker)
            }
        }
        return image(floats: floats, width: width, height: height)
    }

    static func gray(level: Float, size: Int = 16) -> CIImage {
        var floats = [Float](repeating: level, count: size * size * 4)
        for index in stride(from: 3, to: floats.count, by: 4) {
            floats[index] = 1
        }
        return image(floats: floats, width: size, height: size)
    }

    static func image(floats: [Float], width: Int, height: Int) -> CIImage {
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(
            bitmapData: data,
            bytesPerRow: width * 16,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: linearSRGB
        )
    }

    static func context(for image: CIImage) -> RenderContext {
        RenderContext(scale: 1, fullSize: image.extent.size, source: .bitmap)
    }

    private static func hsv(hue: Double, saturation: Double, value: Double) -> (red: Double, green: Double, blue: Double) {
        let sector = hue * 6
        let fraction = sector - floor(sector)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        switch Int(sector) % 6 {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }
}

/// Reads rendered pixels as linear floats, with no color management on the way out.
enum Pixels {
    static let context = CIContext(options: [
        .workingColorSpace: TestImages.linearSRGB,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])

    static func read(_ image: CIImage) -> [Float] {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        var floats = [Float](repeating: 0, count: width * height * 4)
        floats.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        }
        return floats
    }

    static func maxDifference(between first: CIImage, and second: CIImage) -> Float {
        zip(read(first), read(second)).map { abs($0 - $1) }.max() ?? 0
    }

    static func mean(_ image: CIImage) -> SIMD4<Float> {
        let floats = read(image)
        var sum = SIMD4<Float>(repeating: 0)
        for index in stride(from: 0, to: floats.count, by: 4) {
            sum += SIMD4(floats[index], floats[index + 1], floats[index + 2], floats[index + 3])
        }
        return sum / Float(max(floats.count / 4, 1))
    }
}
