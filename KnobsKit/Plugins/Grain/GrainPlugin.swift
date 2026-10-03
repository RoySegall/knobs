import CoreImage

/// Monochrome film grain, seeded by image position so preview frames never flicker.
public struct GrainPlugin: KnobPlugin {
    public let id = "grain"
    public let title = "Grain"
    public let panel = Panel.effects
    public let stage = Stage.effects
    public let order = 20
    public let params: [KnobParam] = [
        .slider(id: "amount", title: "Amount", range: 0...100),
        .slider(id: "size", title: "Size", range: 0...100, default: 25),
        .slider(id: "roughness", title: "Roughness", range: 0...100, default: 50),
    ]

    /// Lattice spacing of each octave relative to the grain size: fine, coarse, clumping envelope.
    static let octaves = [1.0, 2.0, 4.76]

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let amount = values.number("amount") / 100
        guard amount > 0 else { return image }

        // Grain size lives in full-resolution pixels, so the preview shows the export's grain, downscaled.
        let size = 1 + 5 * pow(values.number("size") / 100, 1.4)
        let spacings = Self.octaves.map { size * $0 * context.scale }
        let lattice = spacings.map { 1 / max($0, 1) }
        let strength = spacings.map(Self.averaged)

        return KernelLibrary.color("grain_apply").apply(extent: image.extent, arguments: [
            image,
            CIVector(x: lattice[0], y: lattice[1], z: lattice[2]),
            CIVector(x: strength[0], y: strength[1], z: strength[2]),
            Float(0.1 * amount),
            Float(values.number("roughness") / 100),
        ]) ?? image
    }

    /// Grain level a rendered pixel keeps from an octave of this lattice spacing (render pixels), relative to
    /// point sampling it at max(spacing, 1). Fitted to Lanczos-downscaled renders of the same noise.
    static func averaged(spacing: Double) -> Double {
        spacing < 1 ? 0.674 * pow(spacing, 0.85) : 1 - 0.326 * exp(-1.6 * (spacing - 1))
    }
}
