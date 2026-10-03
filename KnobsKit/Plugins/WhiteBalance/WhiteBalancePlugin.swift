import CoreImage

/// Temp and Tint as offsets from the photo's own white balance, in Adobe's temperature/tint units.
/// RAW moves the decoder's neutral. A bitmap is adapted with Bradford as if it were a RAW shot at D50,
/// so a step looks the same on both.
public struct WhiteBalancePlugin: KnobPlugin {
    public let id = "white_balance"
    public let title = "White Balance"
    public let panel = Panel.color
    public let stage = Stage.raw
    public let order = 5
    public let params: [KnobParam] = [
        .slider(id: "temp", title: "Temp", range: -100...100, track: .gradient([
            KnobColor(red: 0.27, green: 0.47, blue: 0.86),
            KnobColor(red: 0.93, green: 0.84, blue: 0.27),
        ])),
        .slider(id: "tint", title: "Tint", range: -100...100, track: .gradient([
            KnobColor(red: 0.33, green: 0.68, blue: 0.29),
            KnobColor(red: 0.80, green: 0.33, blue: 0.78),
        ])),
    ]

    /// Mireds per slider step. ±100 spans daylight to tungsten from a 5500 K as-shot.
    static let miredsPerStep = 1.5

    public init() {}

    public func configure(raw: CIRAWFilter, values: KnobValues, context: RenderContext) -> Bool {
        let asShot = WhiteBalance(temperature: Double(raw.neutralTemperature), tint: Double(raw.neutralTint))
        let neutral = asShot.shifted(temp: values.number("temp"), tint: values.number("tint"))
        raw.neutralTemperature = Float(neutral.temperature)
        raw.neutralTint = Float(neutral.tint)
        return true
    }

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        guard !values.isNeutral(params: params) else { return image }
        let source = WhiteBalance.d50.shifted(temp: values.number("temp"), tint: values.number("tint"))
        let m = Self.adaptation(from: source.chromaticity, to: WhiteBalance.d50.chromaticity)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0),
            "inputGVector": CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0),
            "inputBVector": CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
    }

    /// Linear sRGB matrix (rows) that maps colors seen under `source` to how they look under `target`.
    /// Scaled so a gray keeps its luminance, which keeps the slider from also acting as exposure.
    static func adaptation(from source: Chromaticity, to target: Chromaticity) -> [[Double]] {
        let sourceCone = product(of: bradford, and: source.whiteXYZ)
        let targetCone = product(of: bradford, and: target.whiteXYZ)
        let gains = (0..<3).map { targetCone[$0] / sourceCone[$0] }
        let cone = (0..<3).map { row in bradford[row].map { $0 * gains[row] } }
        let xyz = product(of: bradfordInverse, and: cone)
        let rgb = product(of: xyzToSRGB, and: product(of: xyz, and: sRGBToXYZ))
        let gray = rgb.map { $0.reduce(0, +) }
        let luminance = 0.2126 * gray[0] + 0.7152 * gray[1] + 0.0722 * gray[2]
        return rgb.map { row in row.map { $0 / luminance } }
    }

    private static let bradford: [[Double]] = [
        [0.8951, 0.2664, -0.1614],
        [-0.7502, 1.7135, 0.0367],
        [0.0389, -0.0685, 1.0296],
    ]

    private static let bradfordInverse: [[Double]] = [
        [0.9869929, -0.1470543, 0.1599627],
        [0.4323053, 0.5183603, 0.0492912],
        [-0.0085287, 0.0400428, 0.9684867],
    ]

    private static let sRGBToXYZ: [[Double]] = [
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ]

    private static let xyzToSRGB: [[Double]] = [
        [3.2404542, -1.5371385, -0.4985314],
        [-0.9692660, 1.8760108, 0.0415560],
        [0.0556434, -0.2040259, 1.0572252],
    ]

    private static func product(of a: [[Double]], and b: [[Double]]) -> [[Double]] {
        (0..<3).map { row in (0..<3).map { column in (0..<3).reduce(0) { $0 + a[row][$1] * b[$1][column] } } }
    }

    private static func product(of a: [[Double]], and vector: [Double]) -> [Double] {
        a.map { row in zip(row, vector).reduce(0) { $0 + $1.0 * $1.1 } }
    }
}

extension WhiteBalancePlugin {
    struct Chromaticity: Equatable {
        let x: Double
        let y: Double

        /// XYZ of a white with this chromaticity at Y = 1.
        var whiteXYZ: [Double] {
            [x / y, 1, (1 - x - y) / y]
        }
    }

    /// A white point in Adobe's (and CIRAWFilter's) units: kelvin, and tint where plus is magenta.
    struct WhiteBalance: Equatable {
        let temperature: Double
        let tint: Double

        /// D50 (x 0.3457, y 0.3585) in these units, from the DNG SDK's inverse of `chromaticity`.
        static let d50 = WhiteBalance(temperature: 5000.7065, tint: 9.562965)

        /// Temp moves in mireds so a step feels the same at any temperature; plus warms the photo.
        func shifted(temp: Double, tint delta: Double) -> WhiteBalance {
            let mireds = 1e6 / temperature - temp * WhiteBalancePlugin.miredsPerStep
            let clamped = min(max(mireds, 1e6 / 50_000), 1e6 / 2_000)
            return WhiteBalance(temperature: 1e6 / clamped, tint: tint + delta)
        }

        /// Robertson's isotherms, the same conversion as the DNG SDK, so RAW and bitmaps share one scale.
        var chromaticity: Chromaticity {
            let table = Self.isotherms
            let mireds = 1e6 / temperature
            let offset = tint / -3000
            let index = table.indices.dropLast().first { mireds < table[$0 + 1].mireds } ?? table.count - 2
            let low = table[index]
            let high = table[index + 1]
            let f = (high.mireds - mireds) / (high.mireds - low.mireds)
            let lowLength = (1 + low.slope * low.slope).squareRoot()
            let highLength = (1 + high.slope * high.slope).squareRoot()
            var du = f / lowLength + (1 - f) / highLength
            var dv = f * low.slope / lowLength + (1 - f) * high.slope / highLength
            let length = (du * du + dv * dv).squareRoot()
            du /= length
            dv /= length
            let u = low.u * f + high.u * (1 - f) + du * offset
            let v = low.v * f + high.v * (1 - f) + dv * offset
            let denominator = u - 4 * v + 2
            return Chromaticity(x: 1.5 * u / denominator, y: v / denominator)
        }

        private static let isotherms: [(mireds: Double, u: Double, v: Double, slope: Double)] = [
            (0, 0.18006, 0.26352, -0.24341), (10, 0.18066, 0.26589, -0.25479), (20, 0.18133, 0.26846, -0.26876),
            (30, 0.18208, 0.27119, -0.28539), (40, 0.18293, 0.27407, -0.30470), (50, 0.18388, 0.27709, -0.32675),
            (60, 0.18494, 0.28021, -0.35156), (70, 0.18611, 0.28342, -0.37915), (80, 0.18740, 0.28668, -0.40955),
            (90, 0.18880, 0.28997, -0.44278), (100, 0.19032, 0.29326, -0.47888), (125, 0.19462, 0.30141, -0.58204),
            (150, 0.19962, 0.30921, -0.70471), (175, 0.20525, 0.31647, -0.84901), (200, 0.21142, 0.32312, -1.0182),
            (225, 0.21807, 0.32909, -1.2168), (250, 0.22511, 0.33439, -1.4512), (275, 0.23247, 0.33904, -1.7298),
            (300, 0.24010, 0.34308, -2.0637), (325, 0.24702, 0.34655, -2.4681), (350, 0.25591, 0.34951, -2.9641),
            (375, 0.26400, 0.35200, -3.5814), (400, 0.27218, 0.35407, -4.3633), (425, 0.28039, 0.35577, -5.3762),
            (450, 0.28863, 0.35714, -6.7262), (475, 0.29685, 0.35823, -8.5955), (500, 0.30505, 0.35907, -11.324),
            (525, 0.31320, 0.35968, -15.628), (550, 0.32129, 0.36011, -23.325), (575, 0.32931, 0.36038, -40.770),
            (600, 0.33724, 0.36051, -116.45),
        ]
    }
}
