import CoreImage

/// The decoder's as-shot settings. A reused CIRAWFilter keeps whatever the previous frame set, so each
/// frame restores these first. A plugin that sets another decoder property must add it here.
struct RAWBaseline {
    private let restorers: [(CIRAWFilter) -> Void]

    init(filter: CIRAWFilter) {
        // Only writes values that differ: an untouched property must not invalidate the decode cache.
        func keep<Value: Equatable>(_ path: ReferenceWritableKeyPath<CIRAWFilter, Value>) -> (CIRAWFilter) -> Void {
            let value = filter[keyPath: path]
            return { if $0[keyPath: path] != value { $0[keyPath: path] = value } }
        }
        restorers = [
            keep(\.exposure),
            keep(\.baselineExposure),
            keep(\.shadowBias),
            keep(\.boostAmount),
            keep(\.boostShadowAmount),
            keep(\.neutralTemperature),
            keep(\.neutralTint),
            keep(\.luminanceNoiseReductionAmount),
            keep(\.colorNoiseReductionAmount),
            keep(\.contrastAmount),
            keep(\.detailAmount),
            keep(\.sharpnessAmount),
            keep(\.moireReductionAmount),
            keep(\.localToneMapAmount),
            keep(\.extendedDynamicRangeAmount),
            keep(\.isGamutMappingEnabled),
            keep(\.isLensCorrectionEnabled),
            { if $0.linearSpaceFilter != nil { $0.linearSpaceFilter = nil } },
        ]
    }

    func restore(on filter: CIRAWFilter) {
        restorers.forEach { $0(filter) }
    }
}
