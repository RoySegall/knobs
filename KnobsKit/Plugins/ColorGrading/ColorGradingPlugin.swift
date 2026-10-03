import CoreImage

/// Lightroom's color grading: shadows, midtones, highlights and global wheels, each with a luminance slider,
/// plus blending (how far the ranges overlap) and balance (where shadows end and highlights begin).
public struct ColorGradingPlugin: KnobPlugin {
    enum Range: String, CaseIterable {
        case shadows
        case midtones
        case highlights
        case global

        var title: String {
            rawValue.capitalized
        }

        var luminanceID: String {
            "\(rawValue)_luminance"
        }
    }

    /// OKLab chroma per unit of lightness that a wheel at full amount adds.
    static let tintStrength = 0.12
    /// Lightness gain at ±100 on a luminance slider.
    static let luminanceStrength = 0.25

    public let id = "color_grading"
    public let title = "Color Grading"
    public let panel = Panel.grading
    public let stage = Stage.color
    public let order = 40
    /// The wheels come first and side by side; their luminance sliders follow in the same order.
    public let params: [KnobParam] = Range.allCases.map { KnobParam.wheel(id: $0.rawValue, title: $0.title) }
        + Range.allCases.map { range in
            KnobParam.slider(id: range.luminanceID, title: "\(range.title) Luminance", range: -100...100, track: ColorGradingPlugin.luminanceTrack)
        }
        + [
            .slider(id: "blending", title: "Blending", range: 0...100, default: 50),
            .slider(id: "balance", title: "Balance", range: -100...100),
        ]

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let wheels = Range.allCases.map { values.wheel($0.rawValue) }
        let luminance = Range.allCases.map { values.number($0.luminanceID) / 100 * Self.luminanceStrength }
        guard wheels.contains(where: { $0.amount > 0 }) || luminance.contains(where: { $0 != 0 }) else { return image }

        let tints = wheels.map { wheel in
            ColorOKLab.direction(wheelHue: wheel.hue) * wheel.amount * Self.tintStrength
        }
        let blending = values.number("blending") / 100
        let balance = values.number("balance") / 100
        let shadowsEnd = 0.35 + 0.65 * blending
        let shape = CIVector(x: pow(2, -balance), y: shadowsEnd, z: 1 - shadowsEnd, w: 0.2 + 0.4 * blending)
        let arguments: [Any] = [
            image,
            CIVector(x: tints[0].x, y: tints[0].y, z: tints[1].x, w: tints[1].y),
            CIVector(x: tints[2].x, y: tints[2].y, z: tints[3].x, w: tints[3].y),
            CIVector(x: luminance[0], y: luminance[1], z: luminance[2], w: luminance[3]),
            shape,
        ]
        return KernelLibrary.color("color_grading_apply").apply(extent: image.extent, arguments: arguments) ?? image
    }

    private static let luminanceTrack: Track = .gradient([
        KnobColor(red: 0.12, green: 0.12, blue: 0.12),
        KnobColor(red: 0.92, green: 0.92, blue: 0.92),
    ])
}
