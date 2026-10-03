import CoreImage
import Testing
@testable import KnobsKit

@Suite("ColorMixerPlugin")
struct ColorMixerTests {
    static let plugin = ColorMixerPlugin()

    static func apply(values: [String: Double], to colors: [SIMD3<Double>]) -> [SIMD3<Double>] {
        ColorSwatches.apply(plugin: plugin, values: values.mapValues { .number($0) }, to: colors)
    }

    /// A band's own color: its center hue at a chroma well inside the gamut.
    static func swatch(band: String, chroma: Double = 0.08) -> SIMD3<Double> {
        let index = ColorMixerPlugin.bands.firstIndex { $0.id == band }!
        return ColorSwatches.color(lightness: 0.65, chroma: chroma, hue: ColorMixerPlugin.centers[index])
    }

    @Suite("params")
    struct Params {
        @Test("should list every hue, then every saturation, then every luminance")
        func order() {
            let ids = ColorMixerTests.plugin.params.map(\.id)
            #expect(ids.count == 24)
            #expect(ids.prefix(8).allSatisfy { $0.hasSuffix("_hue") })
            #expect(ids.dropFirst(8).prefix(8).allSatisfy { $0.hasSuffix("_saturation") })
            #expect(ids.suffix(8).allSatisfy { $0.hasSuffix("_luminance") })
            #expect(ids.first == "red_hue" && ids.last == "magenta_luminance")
        }

        @Test("should give every slider a gradient track")
        func tracks() {
            for param in ColorMixerTests.plugin.params {
                guard case .slider(let slider) = param.kind, case .gradient(let colors) = slider.track else {
                    Issue.record("\(param.id) has no gradient track")
                    continue
                }
                #expect(colors.count >= 2, "\(param.id)")
            }
        }
    }

    @Suite("apply")
    struct Apply {
        @Test("should leave near-grays alone when a band's luminance moves")
        func grays() {
            let grays = stride(from: 0.0, to: 360, by: 45).map { ColorSwatches.color(lightness: 0.6, chroma: 0.002, hue: $0) }
            let output = ColorMixerTests.apply(values: ["blue_luminance": -100, "red_luminance": 100], to: grays)
            for (input, gray) in zip(grays, output) {
                #expect(abs(ColorSwatches.lab(gray).x - ColorSwatches.lab(input).x) < 0.01)
            }
        }

        @Test("should leave reds alone when green saturation changes")
        func isolatesBands() {
            let colors = [ColorMixerTests.swatch(band: "red"), ColorMixerTests.swatch(band: "green")]
            let output = ColorMixerTests.apply(values: ["green_saturation": -100], to: colors)
            #expect(((output[0] - colors[0]) * (output[0] - colors[0])).sum() < 1e-8)
            #expect(ColorSwatches.chroma(output[1]) < 0.002)
        }

        @Test("should double a band's chroma at +100 saturation")
        func saturates() {
            let output = ColorMixerTests.apply(values: ["orange_saturation": 100], to: [ColorMixerTests.swatch(band: "orange", chroma: 0.05)])
            #expect(abs(ColorSwatches.chroma(output[0]) - 0.1) < 2e-3)
        }

        @Test("should darken blues without moving their hue at -100 luminance")
        func luminanceKeepsHue() {
            let blue = ColorMixerTests.swatch(band: "blue")
            let output = ColorMixerTests.apply(values: ["blue_luminance": -100], to: [blue])[0]
            #expect(ColorSwatches.lab(output).x < ColorSwatches.lab(blue).x * 0.75)
            #expect(abs(ColorSwatches.hueDistance(from: ColorSwatches.hue(output), to: ColorSwatches.hue(blue))) < 0.5)
        }

        @Test("should turn red toward orange at +100 hue and toward magenta at -100")
        func rotates() {
            let red = ColorMixerTests.swatch(band: "red")
            let warmer = ColorMixerTests.apply(values: ["red_hue": 100], to: [red])[0]
            let cooler = ColorMixerTests.apply(values: ["red_hue": -100], to: [red])[0]
            #expect(ColorSwatches.hueDistance(from: ColorSwatches.hue(warmer), to: ColorSwatches.hue(red)) > 5)
            #expect(ColorSwatches.hueDistance(from: ColorSwatches.hue(cooler), to: ColorSwatches.hue(red)) < -5)
            #expect(abs(ColorSwatches.chroma(warmer) - 0.08) < 1e-3)
        }

        @Test("should change smoothly across hues with no seam between bands")
        func smooth() {
            let colors = stride(from: 0.0, to: 360, by: 0.5).map { ColorSwatches.color(lightness: 0.7, chroma: 0.06, hue: $0) }
            let output = ColorMixerTests.apply(values: ["orange_saturation": 100, "aqua_saturation": -60, "blue_hue": 100], to: colors)
            let gains = zip(colors, output).map { ColorSwatches.chroma($1) / ColorSwatches.chroma($0) }
            let shifts = zip(colors, output).map { ColorSwatches.hueDistance(from: ColorSwatches.hue($1), to: ColorSwatches.hue($0)) }
            for index in gains.indices.dropFirst() {
                #expect(abs(gains[index] - gains[index - 1]) < 0.05, "gain jumps at \(Double(index) / 2)°")
                #expect(abs(shifts[index] - shifts[index - 1]) < 0.5, "hue jumps at \(Double(index) / 2)°")
            }
            #expect(gains.max()! > 1.95 && gains.min()! < 0.45)
        }
    }
}
