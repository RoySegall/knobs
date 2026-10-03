import Foundation

/// CPU twin of `ColorOKLab.h`, for track colors and wheel directions. Never called per pixel.
enum ColorOKLab {
    /// OKLab (L, a, b) of a linear sRGB color.
    static func lab(linear c: SIMD3<Double>) -> SIMD3<Double> {
        let lms = SIMD3(
            0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z,
            0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z,
            0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
        )
        let root = SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z))
        return SIMD3(
            0.2104542553 * root.x + 0.7936177850 * root.y - 0.0040720468 * root.z,
            1.9779984951 * root.x - 2.4285922050 * root.y + 0.4505937099 * root.z,
            0.0259040371 * root.x + 0.7827717662 * root.y - 0.8086757660 * root.z
        )
    }

    static func linear(lab: SIMD3<Double>) -> SIMD3<Double> {
        let root = SIMD3(
            lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
            lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
            lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        )
        let lms = root * root * root
        return SIMD3(
            4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
            -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
            -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z
        )
    }

    /// OKLab hue angle in degrees, 0..<360.
    static func hue(lab: SIMD3<Double>) -> Double {
        let degrees = atan2(lab.z, lab.y) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Unit (a, b) direction of the fully saturated color at an HSV hue, the hue a color wheel shows.
    static func direction(wheelHue: Double) -> SIMD2<Double> {
        let lab = lab(linear: linear(encoded: hsv(hue: wheelHue)))
        let ab = SIMD2(lab.y, lab.z)
        let length = (ab * ab).sum().squareRoot()
        return length > 0 ? ab / length : .zero
    }

    /// OKLab hue of the fully saturated color at an HSV hue.
    static func hue(wheelHue: Double) -> Double {
        hue(lab: lab(linear: linear(encoded: hsv(hue: wheelHue))))
    }

    /// OKLab lightness of the fully saturated color at an HSV hue.
    static func lightness(wheelHue: Double) -> Double {
        lab(linear: linear(encoded: hsv(hue: wheelHue))).x
    }

    /// Display swatch for an OKLCh color, clipped into sRGB.
    static func swatch(lightness: Double, chroma: Double, hue degrees: Double) -> KnobColor {
        let radians = degrees * .pi / 180
        let c = linear(lab: SIMD3(lightness, chroma * cos(radians), chroma * sin(radians)))
        let encoded = SIMD3(encoded(c.x), encoded(c.y), encoded(c.z))
        return KnobColor(red: encoded.x, green: encoded.y, blue: encoded.z)
    }

    private static func hsv(hue: Double) -> SIMD3<Double> {
        let sector = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let fraction = sector - floor(sector)
        switch Int(sector) {
        case 0: return SIMD3(1, fraction, 0)
        case 1: return SIMD3(1 - fraction, 1, 0)
        case 2: return SIMD3(0, 1, fraction)
        case 3: return SIMD3(0, 1 - fraction, 1)
        case 4: return SIMD3(fraction, 0, 1)
        default: return SIMD3(1, 0, 1 - fraction)
        }
    }

    private static func linear(encoded c: SIMD3<Double>) -> SIMD3<Double> {
        func channel(_ x: Double) -> Double {
            x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return SIMD3(channel(c.x), channel(c.y), channel(c.z))
    }

    private static func encoded(_ x: Double) -> Double {
        let clipped = min(max(x, 0), 1)
        return clipped <= 0.0031308 ? clipped * 12.92 : 1.055 * pow(clipped, 1 / 2.4) - 0.055
    }
}
