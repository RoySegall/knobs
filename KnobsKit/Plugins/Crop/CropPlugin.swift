import CoreImage

/// Crop & straighten, Lightroom style. The crop rect lives in the straightened frame and is kept inside
/// the rotated photo, so a transparent corner never reaches the output.
public struct CropPlugin: KnobPlugin {
    public let id = "crop"
    public let title = "Crop"
    public let panel = Panel.geometry
    public let stage = Stage.geometry
    public let order = 10
    public let params: [KnobParam] = [
        .slider(id: CropSettings.Key.angle, title: "Angle", range: -45...45, decimals: 2),
        .choice(
            id: CropSettings.Key.aspect,
            title: "Aspect",
            options: CropAspect.allCases.map { KnobParam.Choice(id: $0.rawValue, title: $0.title) },
            default: CropAspect.asShot.rawValue
        ),
        .slider(id: CropSettings.Key.left, title: "Left", range: 0...1, default: 0, decimals: 4, presentation: .hidden),
        .slider(id: CropSettings.Key.top, title: "Top", range: 0...1, default: 0, decimals: 4, presentation: .hidden),
        .slider(id: CropSettings.Key.right, title: "Right", range: 0...1, default: 1, decimals: 4, presentation: .hidden),
        .slider(id: CropSettings.Key.bottom, title: "Bottom", range: 0...1, default: 1, decimals: 4, presentation: .hidden),
        .flag(id: CropSettings.Key.flipHorizontal, title: "Flip Horizontal"),
        .flag(id: CropSettings.Key.flipVertical, title: "Flip Vertical"),
    ]

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
        let settings = CropSettings(values: values)
        let rect = settings.effectiveRect(size: extent.size)
        if settings.angle == 0 {
            return aligned(image: image, rect: rect, settings: settings, framing: context.framing)
        }
        return rotated(image: image, rect: rect, settings: settings, framing: context.framing)
    }

    /// No rotation: flips and the crop land on whole pixels, so nothing is resampled.
    private func aligned(image: CIImage, rect: CGRect, settings: CropSettings, framing: Framing) -> CIImage {
        let extent = image.extent
        let flipped = settings.flipHorizontal || settings.flipVertical
        let pixels = CropSettings.pixelRect(rect: rect, size: extent.size)
        if !flipped, framing == .uncropped || pixels == CGRect(origin: .zero, size: extent.size) {
            return image
        }
        var source = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if flipped {
            source = source.transformed(by: CGAffineTransform(
                a: settings.flipHorizontal ? -1 : 1, b: 0,
                c: 0, d: settings.flipVertical ? -1 : 1,
                tx: settings.flipHorizontal ? extent.width : 0,
                ty: settings.flipVertical ? extent.height : 0
            ))
        }
        guard framing == .cropped else { return source }
        return source.cropped(to: pixels).transformed(by: CGAffineTransform(translationX: -pixels.minX, y: -pixels.minY))
    }

    /// One Catmull-Rom pass maps output pixels back to the source. The input is edge-clamped, so taps
    /// past the photo's edge repeat it instead of fading to clear.
    private func rotated(image: CIImage, rect: CGRect, settings: CropSettings, framing: Framing) -> CIImage {
        let extent = image.extent
        let geometry = CropGeometry(size: extent.size, angle: settings.angle)
        let output: CGSize
        let corner: CGPoint
        switch framing {
        case .cropped:
            // Straightened pixels about the photo's center, y up; the output keeps the rect's center.
            output = CGSize(
                width: max(1, (rect.width * extent.width).rounded()),
                height: max(1, (rect.height * extent.height).rounded())
            )
            let center = CGPoint(x: (rect.midX - 0.5) * extent.width, y: (0.5 - rect.midY) * extent.height)
            corner = CGPoint(x: center.x - output.width / 2, y: center.y - output.height / 2)
        case .uncropped:
            let bounds = geometry.boundingSize
            output = CGSize(width: max(1, bounds.width.rounded()), height: max(1, bounds.height.rounded()))
            corner = CGPoint(x: -output.width / 2, y: -output.height / 2)
        }
        let toSource = CGAffineTransform(translationX: corner.x, y: corner.y)
            .concatenating(CGAffineTransform(rotationAngle: settings.angle * .pi / 180))
            .concatenating(CGAffineTransform(scaleX: settings.flipHorizontal ? -1 : 1, y: settings.flipVertical ? -1 : 1))
            .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY))
        let kernel = KernelLibrary.general("crop_resample")
        return kernel.apply(
            extent: CGRect(origin: .zero, size: output),
            roiCallback: { _, area in area.applying(toSource).insetBy(dx: -3, dy: -3) },
            arguments: [
                image.clampedToExtent(),
                CIVector(x: toSource.a, y: toSource.c, z: toSource.tx),
                CIVector(x: toSource.b, y: toSource.d, z: toSource.ty),
                CIVector(cgRect: extent),
                framing == .uncropped ? 1 : 0,
                CIVector(x: output.width, y: output.height),
            ]
        ) ?? image
    }
}

/// Crop aspect ratios. Orientation follows the crop, so 3 : 2 also covers 2 : 3.
public enum CropAspect: String, Sendable, CaseIterable {
    case asShot = "as_shot"
    case free
    case square = "1:1"
    case fourFive = "4:5"
    case fiveSeven = "5:7"
    case threeTwo = "3:2"
    case sixteenNine = "16:9"

    public var title: String {
        switch self {
        case .asShot: "As Shot"
        case .free: "Free"
        case .square: "1 : 1"
        case .fourFive: "4 : 5"
        case .fiveSeven: "5 : 7"
        case .threeTwo: "3 : 2"
        case .sixteenNine: "16 : 9"
        }
    }

    /// Width over height in pixels, turned to match the rect's orientation; nil when free.
    public func ratio(size: CGSize, rect: CGRect) -> Double? {
        let long: Double
        let short: Double
        switch self {
        case .free: return nil
        case .asShot:
            long = max(size.width, size.height)
            short = min(size.width, size.height)
        case .square: (long, short) = (1, 1)
        case .fourFive: (long, short) = (5, 4)
        case .fiveSeven: (long, short) = (7, 5)
        case .threeTwo: (long, short) = (3, 2)
        case .sixteenNine: (long, short) = (16, 9)
        }
        let landscape = rect.width * size.width >= rect.height * size.height
        return landscape ? long / short : short / long
    }
}

/// The crop plugin's values, typed. The canvas tool reads and writes them through this.
public struct CropSettings: Sendable, Equatable {
    public enum Key {
        public static let angle = "angle"
        public static let aspect = "aspect"
        public static let left = "left"
        public static let top = "top"
        public static let right = "right"
        public static let bottom = "bottom"
        public static let flipHorizontal = "flip_horizontal"
        public static let flipVertical = "flip_vertical"
    }

    /// Degrees, positive clockwise. Below a thousandth it is zero, so a near-level drag stays unresampled.
    public var angle: Double
    public var aspect: CropAspect
    /// As requested, normalized with a top-left origin. The rendered rect is `effectiveRect`.
    public var rect: CGRect
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public init(values: KnobValues) {
        let angle = values.number(Key.angle)
        self.angle = abs(angle) < 0.001 ? 0 : angle
        aspect = CropAspect(rawValue: values.choice(Key.aspect)) ?? .asShot
        let left = values.number(Key.left)
        let top = values.number(Key.top)
        rect = CGRect(x: left, y: top, width: values.number(Key.right) - left, height: values.number(Key.bottom) - top).standardized
        flipHorizontal = values.flag(Key.flipHorizontal)
        flipVertical = values.flag(Key.flipVertical)
    }

    public func geometry(size: CGSize) -> CropGeometry {
        CropGeometry(size: size, angle: angle)
    }

    public func ratio(size: CGSize) -> Double? {
        aspect.ratio(size: size, rect: rect)
    }

    public func effectiveRect(size: CGSize) -> CGRect {
        geometry(size: size).effectiveRect(requested: rect, ratio: ratio(size: size))
    }

    /// Stored values for a rect, rounded to a millionth so sidecars stay readable.
    public static func values(rect: CGRect) -> [String: KnobValue] {
        let number = { (value: CGFloat) in KnobValue.number((Double(value) * 1e6).rounded() / 1e6) }
        return [Key.left: number(rect.minX), Key.top: number(rect.minY), Key.right: number(rect.maxX), Key.bottom: number(rect.maxY)]
    }

    /// The crop on whole source pixels, in Core Image's bottom-left coordinates. Always at least one pixel.
    static func pixelRect(rect: CGRect, size: CGSize) -> CGRect {
        let width = size.width.rounded(.down)
        let height = size.height.rounded(.down)
        let left = min(max((rect.minX * size.width).rounded(), 0), width - 1)
        let right = min(max((rect.maxX * size.width).rounded(), left + 1), width)
        let top = min(max((rect.minY * size.height).rounded(), 0), height - 1)
        let bottom = min(max((rect.maxY * size.height).rounded(), top + 1), height)
        return CGRect(x: left, y: height - bottom, width: right - left, height: bottom - top)
    }
}
