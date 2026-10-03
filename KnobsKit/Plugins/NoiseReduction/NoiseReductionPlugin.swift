import CoreImage

/// Luminance and color noise reduction. RAW files use the decoder's own noise reduction;
/// bitmaps get edge-preserving bilateral filters on luma and, at a wider radius, on chroma.
public struct NoiseReductionPlugin: KnobPlugin {
    public let id = "noise_reduction"
    public let title = "Noise Reduction"
    public let panel = Panel.detail
    public let stage = Stage.detail
    public let order = 10
    public let params: [KnobParam] = [
        .slider(id: "luminance", title: "Luminance", range: 0...100),
        .slider(id: "luminance_detail", title: "Luminance Detail", range: 0...100, default: 50),
        .slider(id: "color", title: "Color", range: 0...100),
        .slider(id: "color_detail", title: "Color Detail", range: 0...100, default: 50),
    ]

    public init() {}

    /// Sliders start from the decoder's per-image defaults, so 0 and 50 leave its rendering untouched.
    public func configure(raw: CIRAWFilter, values: KnobValues, context: RenderContext) -> Bool {
        guard raw.isLuminanceNoiseReductionSupported, raw.isColorNoiseReductionSupported else { return false }
        raw.luminanceNoiseReductionAmount = Self.raise(raw.luminanceNoiseReductionAmount, toward: 1, by: values.number("luminance") / 100)
        raw.colorNoiseReductionAmount = Self.raise(raw.colorNoiseReductionAmount, toward: 1, by: values.number("color") / 100)
        if raw.isDetailSupported {
            let detail = values.number("luminance_detail") / 50 - 1
            raw.detailAmount = detail >= 0
                ? Self.raise(raw.detailAmount, toward: 3, by: detail)
                : raw.detailAmount * Float(1 + detail)
        }
        return true
    }

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let luminance = values.number("luminance") / 100
        let color = values.number("color") / 100
        let extent = image.extent
        guard luminance > 0 || color > 0, !extent.isInfinite else { return image }

        var ycc = KernelLibrary.color("noise_reduction_ycc").apply(extent: extent, arguments: [image]) ?? image
        if luminance > 0 {
            ycc = Self.denoiseLuma(ycc, amount: luminance, detail: values.number("luminance_detail") / 100, scale: context.scale)
        }
        guard color > 0 else {
            return KernelLibrary.color("noise_reduction_rgb").apply(extent: extent, arguments: [ycc]) ?? image
        }
        return Self.denoiseChroma(ycc, amount: color, detail: values.number("color_detail") / 100, scale: context.scale) ?? image
    }

    private static func denoiseLuma(_ ycc: CIImage, amount: Double, detail: Double, scale: Double) -> CIImage {
        let spatial = max((0.6 + 2.4 * amount) * scale, 0.5)
        let step = max(1, (spatial * 0.6).rounded())
        let taps = min(3, (2 * spatial / step).rounded(.up))
        // Detail is the threshold: below 50 it widens the range weight and smooths texture, above it keeps texture.
        // A downscaled preview carries less noise, so the threshold shrinks with it to keep the export's texture.
        let range = (0.005 + 0.08 * amount) * pow(2, 3 * (0.5 - detail)) * min(1, 1.5 * scale)
        let reach = step * taps + 1
        return KernelLibrary.general("noise_reduction_luma").apply(
            extent: ycc.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -reach, dy: -reach) },
            arguments: [ycc.clampedToExtent(), bounds(ycc.extent), Float(step), Float(taps), Float(spatial), Float(range)]
        ) ?? ycc
    }

    /// Chroma blotches are wide, so the edge-aware smoothing runs on a box-downsampled copy and comes back
    /// through joint bilateral upsampling that follows the full-resolution luma and color edges.
    private static func denoiseChroma(_ ycc: CIImage, amount: Double, detail: Double, scale: Double) -> CIImage? {
        let extent = ycc.extent
        let sigma = max((1 + 16 * amount) * scale, 0.5)
        let factor = sigma >= 8 ? 8.0 : sigma >= 4 ? 4.0 : sigma >= 1.2 ? 2.0 : 1.0
        let toOrigin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)

        var small = ycc.transformed(by: toOrigin)
        if factor > 1 {
            let size = CGRect(x: 0, y: 0, width: (extent.width / factor).rounded(.up), height: (extent.height / factor).rounded(.up))
            guard let box = KernelLibrary.general("noise_reduction_downsample").apply(
                extent: size,
                roiCallback: { _, rect in rect.applying(CGAffineTransform(scaleX: factor, y: factor)).insetBy(dx: -factor, dy: -factor) },
                arguments: [small.clampedToExtent(), Float(factor)]
            ) else { return nil }
            small = box
        }

        // Color Detail sets how different two colors must be before they stop smoothing into each other.
        let chromaRange = (0.02 + 0.12 * amount) * pow(2, 2.5 * (0.5 - detail))
        let lumaRange = 0.04 + 0.08 * amount
        let ranges = CIVector(x: chromaRange, y: lumaRange)
        let spatial = max(sigma / factor, 0.7)
        let step = max(1, (spatial * 0.67).rounded())
        let reach = 3 * step + 1
        guard let filtered = KernelLibrary.general("noise_reduction_chroma").apply(
            extent: small.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -reach, dy: -reach) },
            arguments: [small.clampedToExtent(), Float(step), Float(spatial), ranges]
        ) else { return nil }
        let upsampled = filtered.clampedToExtent().transformed(by: CGAffineTransform(scaleX: factor, y: factor).concatenating(toOrigin.inverted()))

        // Fades in over the first few steps so the slider leaves 0 without a jump.
        let strength = min(1, amount / 0.1)
        let keep = 0.01 + 0.15 * detail * detail
        return KernelLibrary.general("noise_reduction_merge").apply(
            extent: extent,
            roiCallback: { index, rect in index == 0 ? rect.insetBy(dx: -1, dy: -1) : rect.insetBy(dx: -2 * factor, dy: -2 * factor) },
            arguments: [ycc.clampedToExtent(), upsampled, bounds(extent), CIVector(x: extent.minX, y: extent.minY, z: factor),
                        CIVector(x: chromaRange, y: lumaRange), Float(keep), Float(strength)]
        )
    }

    private static func bounds(_ rect: CGRect) -> CIVector {
        CIVector(x: rect.minX, y: rect.minY, z: rect.maxX, w: rect.maxY)
    }

    private static func raise(_ value: Float, toward limit: Float, by fraction: Double) -> Float {
        value + (max(limit, value) - value) * Float(fraction)
    }
}
