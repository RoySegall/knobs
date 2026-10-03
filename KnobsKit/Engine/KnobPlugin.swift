import CoreImage

/// One knob, or a family of related knobs. Drop a struct conforming to this under `KnobsKit/Plugins/<Name>/`
/// and rebuild; the registry picks it up and the inspector draws its params.
public protocol KnobPlugin: Sendable {
    init()

    /// Stable key in the sidecar file. Never rename it once photos have been edited with it.
    var id: String { get }
    var title: String { get }
    var panel: Panel { get }
    var stage: Stage { get }
    /// Position inside the stage (processing), and inside the panel unless `panelOrder` says otherwise.
    var order: Int { get }
    /// Position inside the panel when it differs from the processing order. Defaults to `order`.
    var panelOrder: Int { get }
    var params: [KnobParam] { get }
    /// True for a plugin whose default is itself a look, such as a camera profile, so the engine runs it
    /// untouched. Such a plugin is exempt from the identity-at-defaults contract. Defaults to false.
    var runsAtDefaults: Bool { get }

    /// Tunes the RAW decoder. Return false to be handled by `apply` instead.
    func configure(raw: CIRAWFilter, values: KnobValues, context: RenderContext) -> Bool

    /// Must return the input unchanged when every value is at its default.
    func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage
}

extension KnobPlugin {
    public var panelOrder: Int {
        order
    }

    public var runsAtDefaults: Bool {
        false
    }

    public func configure(raw: CIRAWFilter, values: KnobValues, context: RenderContext) -> Bool {
        false
    }

    public func param(_ id: String) -> KnobParam? {
        params.first { $0.id == id }
    }
}
