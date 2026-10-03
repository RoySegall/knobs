import CoreImage
import Foundation

extension RenderEngine {
    /// Lightroom's Auto: exposure, contrast, highlights, shadows, whites, blacks, vibrance and saturation
    /// for the photo as `document` renders it, as plugin id → param id → value. The knobs Auto sets are
    /// measured at their defaults and everything else as it stands, so running it twice gives one answer.
    public func autoTone(photo: Photo, document: EditDocument) -> [String: [String: KnobValue]] {
        let base = AutoTone.clearing(document)
        let session = previewSession(photo: photo, maxPixelSize: AutoTone.sampleSize)
        let settings = AutoTone.solve { settings in
            autoToneStats(image: session.image(document: settings.applied(to: base, engine: self), skipping: []))
        }
        return AutoTone.resolved(values: settings.values, engine: self)
    }

    /// Histograms the render on the GPU, so only a few kilobytes come back.
    func autoToneStats(image: CIImage) -> AutoTone.Stats {
        // Whole pixels only: a partly covered edge pixel would count as black.
        let extent = image.extent
        let inner = CGRect(
            x: extent.minX.rounded(.up),
            y: extent.minY.rounded(.up),
            width: extent.maxX.rounded(.down) - extent.minX.rounded(.up),
            height: extent.maxY.rounded(.down) - extent.minY.rounded(.up)
        )
        let bins = AutoTone.Stats.bins
        guard inner.width >= 1, inner.height >= 1,
              let measured = KernelLibrary.color("auto_tone_measure").apply(extent: extent, arguments: [image, Float(AutoTone.chromaScale)])
        else { return AutoTone.Stats() }
        let histogram = measured.applyingFilter("CIAreaHistogram", parameters: [
            kCIInputExtentKey: CIVector(cgRect: inner),
            "inputCount": bins,
            "inputScale": 1,
        ])
        var floats = [Float](repeating: 0, count: bins * 4)
        floats.withUnsafeMutableBytes { buffer in
            context.render(
                histogram,
                toBitmap: buffer.baseAddress!,
                rowBytes: bins * 16,
                bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
                format: .RGBAf,
                colorSpace: nil
            )
        }
        func channel(_ offset: Int) -> [Double] {
            (0..<bins).map { Double(floats[$0 * 4 + offset]) }
        }
        return AutoTone.Stats(luma: channel(0), high: channel(1), chroma: channel(2))
    }
}

/// Auto Tone renders a small copy with a proposal, measures it in sRGB gamma, and corrects. The knobs
/// are non-linear and interact, so each round holds the key while the ends and the spread move.
enum AutoTone {
    /// Long edge of the copy Auto measures.
    static let sampleSize = 512

    /// The knobs Auto sets, by plugin id.
    static var knobs: [String: [String]] {
        Settings().values.mapValues { Array($0.keys) }
    }

    /// The document with every knob Auto sets back at its default.
    static func clearing(_ document: EditDocument) -> EditDocument {
        var cleared = document
        for (plugin, params) in knobs {
            var values = cleared.plugins[plugin] ?? [:]
            params.forEach { values[$0] = nil }
            cleared.plugins[plugin] = values.isEmpty ? nil : values
        }
        return cleared
    }

    /// Rounded to each slider's step and clamped to its range, as the inspector stores them.
    static func resolved(values: [String: [String: KnobValue]], engine: RenderEngine) -> [String: [String: KnobValue]] {
        var resolved: [String: [String: KnobValue]] = [:]
        for (pluginID, params) in values {
            guard let plugin = engine.plugin(id: pluginID) else { continue }
            for (paramID, value) in params {
                guard let param = plugin.param(paramID), case .slider(let slider) = param.kind, case .number(let number) = value
                else { continue }
                let step = pow(10, Double(slider.decimals))
                resolved[pluginID, default: [:]][paramID] = param.resolve(.number((number * step).rounded() / step))
            }
        }
        return resolved
    }

    /// One proposal, in slider units.
    struct Settings: Equatable {
        var exposure = 0.0
        var contrast = 0.0
        var highlights = 0.0
        var shadows = 0.0
        var whites = 0.0
        var blacks = 0.0
        var vibrance = 0.0
        var saturation = 0.0

        var values: [String: [String: KnobValue]] {
            [
                "exposure": ["exposure": .number(exposure)],
                "contrast": ["contrast": .number(contrast)],
                "tone": [
                    "highlights": .number(highlights),
                    "shadows": .number(shadows),
                    "whites": .number(whites),
                    "blacks": .number(blacks),
                ],
                "vibrance": ["vibrance": .number(vibrance)],
                "saturation": ["saturation": .number(saturation)],
            ]
        }

        func applied(to document: EditDocument, engine: RenderEngine) -> EditDocument {
            var document = document
            for (pluginID, params) in values {
                guard let plugin = engine.plugin(id: pluginID) else { continue }
                for (paramID, value) in params {
                    if let param = plugin.param(paramID) {
                        document.set(value: value, param: param, plugin: pluginID)
                    }
                }
            }
            return document
        }
    }

    /// What Auto reads off a render. Tones are sRGB-encoded, so equal steps look equal.
    struct Stats {
        var median = 0.0
        var mean = 0.0
        var p25 = 0.0
        var p75 = 0.0
        /// Brightest channel's 99.5th percentile: where the whites end.
        var white = 0.0
        /// Luminance 0.5th percentile: where the blacks end.
        var black = 0.0
        /// Share of the photo in the dark tones, weighted toward black.
        var shadowMass = 0.0
        /// Share of the photo in the bright tones, weighted toward white.
        var highlightMass = 0.0
        /// Share whose brightest channel is at white.
        var clipped = 0.0
        /// Share at black.
        var crushed = 0.0
        /// Mean OKLab chroma.
        var chroma = 0.0

        static let bins = 1024

        init() {}

        /// Per-bin shares over 0...1: luminance, brightest channel, and chroma times `chromaScale`.
        init(luma: [Double], high: [Double], chroma chromaBins: [Double]) {
            let total = luma.reduce(0, +)
            guard total > 0 else { return }
            let count = Double(luma.count)
            func center(_ bin: Int) -> Double {
                (Double(bin) + 0.5) / count
            }
            func percentile(of histogram: [Double], at fraction: Double) -> Double {
                var seen = 0.0
                for (bin, share) in histogram.enumerated() {
                    seen += share
                    if seen >= fraction * total { return center(bin) }
                }
                return 1
            }
            func average(of histogram: [Double], weight: (Double) -> Double) -> Double {
                histogram.enumerated().reduce(0) { $0 + $1.element * weight(center($1.offset)) } / total
            }
            median = percentile(of: luma, at: 0.5)
            mean = average(of: luma) { $0 }
            p25 = percentile(of: luma, at: 0.25)
            p75 = percentile(of: luma, at: 0.75)
            white = percentile(of: high, at: 0.995)
            black = percentile(of: luma, at: 0.005)
            shadowMass = average(of: luma) { 1 - AutoTone.smoothstep(from: 0.08, to: 0.35, at: $0) }
            highlightMass = average(of: luma) { AutoTone.smoothstep(from: 0.7, to: 0.95, at: $0) }
            clipped = average(of: high) { $0 >= 0.995 ? 1 : 0 }
            crushed = average(of: luma) { $0 <= 0.005 ? 1 : 0 }
            chroma = average(of: chromaBins) { $0 } / AutoTone.chromaScale
        }

        /// Where the midtones sit: between the median and the mean, so a bright sky counts but does not rule.
        var key: Double {
            0.5 * median + 0.5 * mean
        }

        var spread: Double {
            p75 - p25
        }
    }

    /// OKLab chroma rarely passes 0.4; scaled so the histogram spreads over 0...1.
    static let chromaScale = 2.5

    static func encoded(_ x: Double) -> Double {
        let clamped = min(max(x, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    static func linear(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    static func smoothstep(from edge0: Double, to edge1: Double, at x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: Solver

extension AutoTone {
    /// Renders through `measure` five times: as is, with exposure alone, then three rounds that hold the
    /// key and move the ends and the spread toward their goals.
    static func solve(measure: (Settings) -> Stats) -> Settings {
        let original = measure(Settings())
        let key = keyGoal(original: original)
        var settings = Settings()
        settings.exposure = exposureStep(from: original.key, to: key, gain: 1)

        let normalized = measure(settings)
        // Stops of key per stop of exposure, seen on the way here. The display shoulder makes it less than one.
        let gain = abs(settings.exposure) > 0.1
            ? min(max(log2(linear(normalized.key) / max(linear(original.key), 1e-4)) / settings.exposure, 0.4), 1)
            : 1
        // Highlights compress everything above mid-gray, which flattens a bright photo; it gets Whites instead.
        let highKey = smoothstep(from: 0.62, to: 0.8, at: key)
        settings.highlights = -min(10 + 160 * normalized.highlightMass, 60) * (1 - 0.8 * highKey)
        settings.shadows = min(110 * normalized.shadowMass, 50)
        settings.vibrance = min(max((0.075 - normalized.chroma) * 600, 0), 35)
        settings.saturation = min(max((0.05 - normalized.chroma) * 200, 0), 8)

        let goals = Goals(normalized: normalized)
        for _ in 0..<3 {
            let stats = measure(settings)
            settings.exposure += exposureStep(from: stats.key, to: key, gain: gain)
            let spreadError = goals.spread - stats.spread
            settings.contrast += contrastStep(stats: stats, error: spreadError) * (1 - highKey)
            var whites = whitesStep(from: stats.white, to: goals.white)
            // A bright photo gets its spread from the top, as long as that does not clip more of it.
            if stats.clipped < goals.clipped {
                whites += max(spreadError, 0) * highKey / whitesSlope(at: stats.p75)
            } else if stats.clipped > goals.clipped * 1.5 + 0.01 {
                whites = min(whites, -5)
            }
            settings.whites += min(max(whites, -15), 20)
            let blacks = blacksStep(from: stats.black, to: goals.black)
            // Lifting only backs off an earlier pull, unless the photo is crushed to begin with.
            settings.blacks = blacks > 0 && !goals.liftsBlacks
                ? min(settings.blacks + blacks, max(settings.blacks, 0))
                : settings.blacks + blacks
            settings.contrast = min(max(settings.contrast, -10), 20)
            settings.whites = min(max(settings.whites, -10), 45)
            settings.blacks = min(max(settings.blacks, -40), 10)
        }
        settings.exposure = min(max(settings.exposure, -2.5), 3)
        return settings
    }

    /// Where the ends and the midtone spread should land: part of the way from where they are, and
    /// only as far as their knob reaches.
    struct Goals {
        let white: Double
        let black: Double
        let spread: Double
        /// Most of the photo Auto lets sit at white.
        let clipped: Double
        /// True when so much sits at black that Blacks should lift it.
        let liftsBlacks: Bool

        init(normalized stats: Stats) {
            // Whites bend tones above mid-gray, so a photo with nothing bright is left to exposure.
            let whiteReach = AutoTone.smoothstep(from: 0.55, to: 0.75, at: stats.white)
            white = stats.white < AutoTone.whiteTarget
                ? stats.white + (AutoTone.whiteTarget - stats.white) * 0.7 * whiteReach
                : 0.985
            clipped = max(stats.clipped, 0.005)
            // Blacks bend the darkest quarter, so a lifted end is left to contrast and exposure.
            let blackReach = 1 - AutoTone.smoothstep(from: 0.08, to: 0.22, at: stats.black)
            liftsBlacks = stats.black <= AutoTone.blackTarget && stats.crushed > 0.02
            if stats.black > AutoTone.blackTarget {
                black = stats.black + (AutoTone.blackTarget - stats.black) * 0.5 * blackReach
            } else {
                black = liftsBlacks ? 0.01 : stats.black
            }
            let current = stats.spread
            spread = current < 0.22 ? current + (0.22 - current) * 0.5 : current - max(current - 0.4, 0) * 0.5
        }
    }

    /// The key Auto aims for: part of the way to a pleasing middle, brightened further when nothing in
    /// the photo reaches white, so a dim photo gets its highlights back.
    static func keyGoal(original: Stats) -> Double {
        let target = targetKey(original: original.key)
        let toKey = log2(linear(target) / max(linear(original.key), 1e-4))
        let toWhite = log2(linear(0.95) / max(linear(original.white), 1e-4))
        let headroom = 0.7 * min(max(toWhite - max(toKey, 0), 0), 1.2)
        return encoded(linear(target) * exp2(headroom))
    }

    /// A bright scene stays brighter than a dark one, and a very dark one moves least, so snow stays
    /// white and night stays night.
    static func targetKey(original: Double) -> Double {
        let middle = 0.5
        let offset = original - middle
        let kept = offset > 0 ? 0.8 : 0.5 + 0.35 * smoothstep(from: 0.15, to: 0.4, at: -offset)
        return middle + offset * kept
    }

    /// Stops that move the key from `current` to `target`, at most one and a half per round.
    static func exposureStep(from current: Double, to target: Double, gain: Double) -> Double {
        let step = log2(linear(target) / max(linear(current), 1e-4)) / gain
        return min(max(step, -1.5), 1.5)
    }

    static let whiteTarget = 0.975
    static let blackTarget = 0.025

    /// Change in an sRGB tone per Whites step, from the Tone plugin's curve.
    static func whitesSlope(at tone: Double) -> Double {
        let u = max((tone - 0.5) / 0.5, 0.3)
        return 0.5 * u * u * 1.1 / 100
    }

    /// Whites mostly push the end up toward white; Highlights is what brings bright tones down.
    static func whitesStep(from current: Double, to goal: Double) -> Double {
        max((goal - current) / whitesSlope(at: current), -5)
    }

    static func blacksStep(from current: Double, to goal: Double) -> Double {
        let u = max((0.3 - current) / 0.3, 0.3)
        let slope = 0.3 * u * u * (goal < current ? 0.6 : 0.7) / 100
        return min(max((goal - current) / slope, -15), 15)
    }

    /// Contrast steps that widen the midtone spread by `error`: the curve's slope at mid-gray is 2^(c/100).
    static func contrastStep(stats: Stats, error: Double) -> Double {
        let perStep = max(stats.spread, 0.05) * log(2) / 100
        return min(max(error / perStep, -10), 15)
    }
}
