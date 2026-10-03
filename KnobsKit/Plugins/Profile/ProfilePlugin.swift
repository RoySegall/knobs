import CoreImage
import Synchronization

/// Lightroom's Profile row: how the scene-linear edit becomes a display picture. Camera matches the JPEG
/// the camera embedded in the RAW, fitted once per photo; Neutral is the decoder's own rendering with the
/// engine's highlight roll-off. It runs after every other knob, so they keep the decoder's headroom.
public struct ProfilePlugin: KnobPlugin {
    public let id = "profile"
    public let title = "Profile"
    public let panel = Panel.light
    public let stage = Stage.output
    public let order = 10
    public let panelOrder = 1
    public let runsAtDefaults = true
    public let params: [KnobParam] = [
        .choice(
            id: "look",
            title: "Profile",
            options: [KnobParam.Choice(id: "camera", title: "Camera"), KnobParam.Choice(id: "neutral", title: "Neutral")],
            default: "camera"
        ),
        .slider(id: "amount", title: "Amount", range: 0...100, default: 100),
    ]

    /// The last lookup row built. Every other knob re-runs this plugin each frame while its look stands still.
    private static let cache = Mutex<(key: CacheKey, matrix: [Float], toe: Float, image: CIImage)?>(nil)

    private struct CacheKey: Equatable {
        let look: CameraLook
        let amount: Float
    }

    public init() {}

    public func rendersDisplay(values: KnobValues, context: RenderContext) -> Bool {
        look(values: values, context: context) != nil
    }

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        guard let look = look(values: values, context: context) else { return image }
        let (matrix, toe, table) = Self.table(look: look, amount: Float(values.number("amount") / 100))
        let tableExtent = table.extent
        return KernelLibrary.general("profile_apply").apply(
            extent: image.extent,
            roiCallback: { index, rect in index == 0 ? rect : tableExtent },
            arguments: [
                image,
                table,
                CIVector(x: CGFloat(matrix[0]), y: CGFloat(matrix[1]), z: CGFloat(matrix[2])),
                CIVector(x: CGFloat(matrix[3]), y: CGFloat(matrix[4]), z: CGFloat(matrix[5])),
                CIVector(x: CGFloat(matrix[6]), y: CGFloat(matrix[7]), z: CGFloat(matrix[8])),
                CIVector(
                    x: CGFloat(CameraLook.lowStop),
                    y: CGFloat(ToneTable.samplesPerStop),
                    z: CGFloat(ToneTable.width - 1),
                    w: CGFloat(toe)
                ),
            ]
        ) ?? image
    }

    /// The camera look, or nil where the neutral rendering stands: bitmaps (the camera already rendered
    /// them), the neutral choice and zero amount.
    func look(values: KnobValues, context: RenderContext) -> CameraLook? {
        guard context.source == .raw, values.choice("look") == "camera", values.number("amount") > 0 else { return nil }
        return context.analysis.cameraLook ?? .fallback
    }

    private static func table(look: CameraLook, amount: Float) -> (matrix: [Float], toe: Float, image: CIImage) {
        let key = CacheKey(look: look, amount: amount)
        if let cached = cache.withLock({ $0 }), cached.key == key {
            return (cached.matrix, cached.toe, cached.image)
        }
        let (table, matrix) = rendering(look: look, amount: amount)
        var samples = [Float](repeating: 1, count: ToneTable.width * 4)
        for (index, value) in table.values.enumerated() {
            samples[index * 4] = value
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(
            bitmapData: data,
            bytesPerRow: ToneTable.width * 16,
            size: CGSize(width: ToneTable.width, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
        cache.withLock { $0 = (key, matrix, table.toe, image) }
        return (matrix, table.toe, image)
    }

    /// The look at a partial amount, like Lightroom's profile amount: curve and matrix move from the
    /// neutral roll-off toward the camera's together. At 1 it is the camera look itself.
    static func rendering(look: CameraLook, amount: Float) -> (table: ToneTable, matrix: [Float]) {
        let camera = ToneTable(look: look)
        guard amount < 1 else { return (camera, look.matrix) }
        let knee = RenderEngine.rawKnee
        let white = RenderEngine.rawWhite
        let bend = (white - 1) / ((1 - knee) * (white - knee))
        let values = camera.values.indices.map { index in
            let x = exp2(CameraLook.lowStop + Float(index) / ToneTable.samplesPerStop)
            let neutral = x <= knee ? x : knee + (x - knee) / (1 + (x - knee) * bend)
            return min(1, neutral + (camera.values[index] - neutral) * amount)
        }
        let matrix = zip(CameraLook.identityMatrix, look.matrix).map { $0 + ($1 - $0) * amount }
        return (ToneTable(values: values, toe: 1 + (camera.toe - 1) * amount), matrix)
    }
}
