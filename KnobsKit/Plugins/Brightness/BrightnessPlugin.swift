import CoreImage

/// Lifts or darkens the midtones while black and white stay put, like Apple Photos' Brightness.
public struct BrightnessPlugin: KnobPlugin {
    public let id = "brightness"
    public let title = "Brightness"
    public let panel = Panel.light
    public let stage = Stage.tone
    public let order = 5
    public let panelOrder = 15
    public let params: [KnobParam] = [
        .slider(id: "brightness", title: "Brightness", range: -100...100),
    ]

    /// Gamma exponent at ±100: mid-gray moves from 50% to about 66% (or 34%) in display terms.
    static let maxStrength = 0.75

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let amount = values.number("brightness") / 100
        guard amount != 0 else { return image }
        let gamma = Float(pow(2, -amount * Self.maxStrength))
        return KernelLibrary.color("brightness_apply").apply(extent: image.extent, arguments: [image, gamma]) ?? image
    }
}
