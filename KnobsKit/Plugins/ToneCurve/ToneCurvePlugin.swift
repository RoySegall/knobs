import CoreImage
import Synchronization

/// Lightroom's Tone Curve: parametric region sliders, the RGB point curve and per-channel curves,
/// applied in sRGB gamma space through one lookup row built on the CPU from the values alone.
public struct ToneCurvePlugin: KnobPlugin {
    public let id = "tone_curve"
    public let title = "Tone Curve"
    public let panel = Panel.curve
    public let stage = Stage.tone
    public let order = 50
    public let params: [KnobParam] = [
        .curve(id: "rgb", title: "RGB", group: "point_curve"),
        .curve(id: "red", title: "Red", group: "point_curve", tint: KnobColor(red: 0.96, green: 0.38, blue: 0.38)),
        .curve(id: "green", title: "Green", group: "point_curve", tint: KnobColor(red: 0.42, green: 0.86, blue: 0.46)),
        .curve(id: "blue", title: "Blue", group: "point_curve", tint: KnobColor(red: 0.42, green: 0.62, blue: 1)),
        .slider(id: "highlights", title: "Highlights", range: -100...100),
        .slider(id: "lights", title: "Lights", range: -100...100),
        .slider(id: "darks", title: "Darks", range: -100...100),
        .slider(id: "shadows", title: "Shadows", range: -100...100),
    ]

    /// The last table built. Other knobs re-run this plugin every frame while its own values stand still.
    private static let cache = Mutex<(values: KnobValues, lut: ToneCurveLUT, image: CIImage)?>(nil)

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        guard !values.isNeutral(params: params) else { return image }
        let (lut, table) = Self.table(values: values)
        let tableExtent = table.extent
        return KernelLibrary.general("tone_curve_apply").apply(
            extent: image.extent,
            roiCallback: { index, rect in index == 0 ? rect : tableExtent },
            arguments: [
                image,
                table,
                Float(ToneCurveLUT.width - 1),
                CIVector(lut.low),
                CIVector(lut.lowSlope),
                CIVector(lut.high),
                CIVector(lut.highSlope),
            ]
        ) ?? image
    }

    private static func table(values: KnobValues) -> (ToneCurveLUT, CIImage) {
        if let cached = cache.withLock({ $0 }), cached.values == values {
            return (cached.lut, cached.image)
        }
        let lut = lut(values: values)
        let image = lut.image
        cache.withLock { $0 = (values, lut, image) }
        return (lut, image)
    }

    static func lut(values: KnobValues) -> ToneCurveLUT {
        let parametric = ParametricCurve.curve(
            shadows: values.number("shadows"),
            darks: values.number("darks"),
            lights: values.number("lights"),
            highlights: values.number("highlights")
        )
        return ToneCurveLUT(
            parametric: parametric,
            rgb: curve(values: values, id: "rgb"),
            channels: ["red", "green", "blue"].map { curve(values: values, id: $0) }
        )
    }

    /// Sidecars are hand-editable, so points are pulled back into the unit square.
    private static func curve(values: KnobValues, id: String) -> MonotoneCurve {
        let unit = { (value: Double) in min(max(value, 0), 1) }
        return MonotoneCurve(points: values.curve(id).map { CurvePoint(x: unit($0.x), y: unit($0.y)) })
    }
}

private extension CIVector {
    convenience init(_ vector: SIMD3<Double>) {
        self.init(x: vector.x, y: vector.y, z: vector.z)
    }
}
