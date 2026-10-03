import CoreImage

/// Fast guided filter (He & Sun 2015): the per-window linear coefficients are solved on a small copy
/// and upsampled, so a large radius costs little more than the full-resolution pass that applies them.
enum GuidedFilter {
    /// Guides and inputs are expected around 0...1; shifting them by this keeps the half-float moments precise.
    private static let center: Float = 0.5

    /// Self-guided filter on the r channel. Returns the mean coefficients, a in r and b in g; the
    /// edge-aware result is `a * I + b` with I at any resolution.
    static func grayCoefficients(guide: CIImage, radius: Double, epsilon: Double) -> CIImage {
        let extent = guide.extent
        let moments = color("guided_gray_moments", extent: extent, arguments: [guide, center])
        let means = boxMean(moments, radius: radius)
        let coefficients = color("guided_gray_coefficients", extent: extent, arguments: [means, epsilon, center])
        return boxMean(coefficients, radius: radius)
    }

    /// Color-guided filter of `input`'s r channel (expected in 0...1). Returns the mean coefficients, a in
    /// rgb and b in alpha; the result is `dot(a, I) + b`. Edges between regions of equal brightness but
    /// different color survive. `guideCenter` is the guide value where edges need the most precision.
    static func colorCoefficients(
        guide: CIImage,
        input: CIImage,
        radius: Double,
        epsilon: Double,
        guideCenter: CIVector = CIVector(x: 0.5, y: 0.5, z: 0.5)
    ) -> CIImage {
        let extent = guide.extent
        let center = guideCenter
        let m1 = boxMean(color("guided_color_moments_1", extent: extent, arguments: [guide, input, center]), radius: radius)
        let m2 = boxMean(color("guided_color_moments_2", extent: extent, arguments: [guide, input, center]), radius: radius)
        let m3 = boxMean(color("guided_color_moments_3", extent: extent, arguments: [guide, center]), radius: radius)
        let m4 = boxMean(color("guided_color_moments_4", extent: extent, arguments: [guide, center]), radius: radius)
        let coefficients = color("guided_color_coefficients", extent: extent, arguments: [m1, m2, m3, m4, epsilon, center])
        return boxMean(coefficients, radius: radius)
    }

    /// Mean over a (2r+1)² window, edge pixels repeated so borders aren't darkened and the extent is kept.
    static func boxMean(_ image: CIImage, radius: Double) -> CIImage {
        box(image, width: 2 * radius.rounded() + 1)
    }

    /// Downscaled copy: a box prefilter about one output pixel wide, then bilinear sampling. Much cheaper
    /// than Lanczos and plenty for window statistics. The extent is the scaled one, rounded out.
    static func downsample(_ image: CIImage, scale: Double) -> CIImage {
        guard scale < 1 else { return image }
        let extent = image.extent.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        return box(image, width: 1 / scale)
            .clampedToExtent()
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: extent)
    }

    /// CIBoxBlur's "radius" is really the box width, rounded down to an odd number of pixels.
    private static func box(_ image: CIImage, width: Double) -> CIImage {
        guard width >= 3 else { return image }
        return image.clampedToExtent()
            .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: width])
            .cropped(to: image.extent)
    }

    /// Bilinear upsample of a `downsample(scale:)` result back onto `extent`.
    static func upsample(_ image: CIImage, scale: Double, to extent: CGRect) -> CIImage {
        guard scale < 1 else { return image.cropped(to: extent) }
        return image.clampedToExtent()
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
    }

    private static func color(_ name: String, extent: CGRect, arguments: [Any]) -> CIImage {
        KernelLibrary.color(name).apply(extent: extent, arguments: arguments) ?? .empty()
    }
}
