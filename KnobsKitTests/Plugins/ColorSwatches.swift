import CoreImage
@testable import KnobsKit

/// Rows of single-pixel swatches for the color plugin tests, built and measured in OKLab.
enum ColorSwatches {
    /// Linear sRGB of an OKLCh color.
    static func color(lightness: Double, chroma: Double, hue: Double) -> SIMD3<Double> {
        let radians = hue * .pi / 180
        return ColorOKLab.linear(lab: SIMD3(lightness, chroma * cos(radians), chroma * sin(radians)))
    }

    /// Linear sRGB of an 8-bit sRGB color.
    static func encoded(red: Double, green: Double, blue: Double) -> SIMD3<Double> {
        func channel(_ value: Double) -> Double {
            let x = value / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return SIMD3(channel(red), channel(green), channel(blue))
    }

    static func gray(_ level: Double) -> SIMD3<Double> {
        SIMD3(repeating: level)
    }

    /// Runs the plugin over one row of swatches and reads them back, in order.
    static func apply(plugin: any KnobPlugin, values stored: [String: KnobValue], to colors: [SIMD3<Double>]) -> [SIMD3<Double>] {
        var floats: [Float] = []
        for color in colors {
            floats += [Float(color.x), Float(color.y), Float(color.z), 1]
        }
        let image = TestImages.image(floats: floats, width: colors.count, height: 1)
        let values = KnobValues(params: plugin.params, stored: stored)
        let output = Pixels.read(plugin.apply(image: image, values: values, context: TestImages.context(for: image)))
        return colors.indices.map { index in
            SIMD3(Double(output[index * 4]), Double(output[index * 4 + 1]), Double(output[index * 4 + 2]))
        }
    }

    static func lab(_ color: SIMD3<Double>) -> SIMD3<Double> {
        ColorOKLab.lab(linear: color)
    }

    static func chroma(_ color: SIMD3<Double>) -> Double {
        let lab = lab(color)
        return (lab.y * lab.y + lab.z * lab.z).squareRoot()
    }

    static func hue(_ color: SIMD3<Double>) -> Double {
        ColorOKLab.hue(lab: lab(color))
    }

    static func luminance(_ color: SIMD3<Double>) -> Double {
        0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
    }

    /// Signed distance between two hue angles, -180...180.
    static func hueDistance(from first: Double, to second: Double) -> Double {
        let difference = (first - second).truncatingRemainder(dividingBy: 360)
        return difference > 180 ? difference - 360 : (difference < -180 ? difference + 360 : difference)
    }

    /// Lowest Display P3 channel; below zero means the color clips on export.
    static func lowestP3(_ color: SIMD3<Double>) -> Double {
        let red = 0.8224620 * color.x + 0.1775380 * color.y
        let green = 0.0331942 * color.x + 0.9668058 * color.y
        let blue = 0.0170826 * color.x + 0.0723974 * color.y + 0.9105199 * color.z
        return min(red, green, blue)
    }
}
