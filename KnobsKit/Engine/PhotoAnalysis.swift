import CoreImage

/// Facts about a photo measured once when it loads, for plugins that adapt to the photo. Measuring
/// happens on a small decode, so it costs a fraction of opening the photo.
public struct PhotoAnalysis: Sendable {
    /// Brightest channel value the decoder produces: where the sensor clipped. 1 for bitmaps.
    public var clipLevel: Float

    public init(clipLevel: Float = 1) {
        self.clipLevel = clipLevel
    }

    /// Long edge of the decode the measurements are taken from.
    static let sampleSize: CGFloat = 512

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])

    static func measure(source: Photo.Source, fullSize: CGSize) -> PhotoAnalysis {
        guard case .raw(let data, let typeIdentifier) = source,
              let filter = CIRAWFilter(imageData: data, identifierHint: typeIdentifier)
        else { return PhotoAnalysis() }
        filter.extendedDynamicRangeAmount = Photo.rawHeadroom
        filter.scaleFactor = Float(min(1, sampleSize / max(fullSize.width, fullSize.height)))
        guard let image = filter.outputImage else { return PhotoAnalysis() }
        let maximum = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(maximum, toBitmap: buffer.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        let clip = max(pixel[0], pixel[1], pixel[2])
        return PhotoAnalysis(clipLevel: clip.isFinite && clip > 0 ? clip : 1)
    }
}
