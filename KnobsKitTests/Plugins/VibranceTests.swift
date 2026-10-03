import CoreImage
import Testing
@testable import KnobsKit

@Suite("VibrancePlugin")
struct VibranceTests {
    static let plugin = VibrancePlugin()

    static func gain(amount: Double, for colors: [SIMD3<Double>]) -> [Double] {
        let output = ColorSwatches.apply(plugin: plugin, values: ["vibrance": .number(amount)], to: colors)
        return zip(colors, output).map { ColorSwatches.chroma($1) / ColorSwatches.chroma($0) }
    }

    @Suite("apply")
    struct Apply {
        @Test("should leave grays and black untouched at both extremes")
        func neutrals() {
            let neutrals = [ColorSwatches.gray(0), ColorSwatches.gray(0.5), ColorSwatches.gray(2)]
            for amount in [-100.0, 100] {
                let output = ColorSwatches.apply(plugin: VibranceTests.plugin, values: ["vibrance": .number(amount)], to: neutrals)
                for (input, gray) in zip(neutrals, output) {
                    #expect(abs(gray.x - input.x) < 1e-3 * max(input.x, 1) && abs(gray.z - input.z) < 1e-3 * max(input.z, 1))
                }
            }
        }

        @Test("should boost a muted color more than a saturated one of the same hue")
        func favorsMuted() {
            let muted = ColorSwatches.color(lightness: 0.6, chroma: 0.04, hue: 250)
            let vivid = ColorSwatches.color(lightness: 0.6, chroma: 0.15, hue: 250)
            let gains = VibranceTests.gain(amount: 100, for: [muted, vivid])
            #expect(gains[0] > 1.6)
            #expect(gains[1] > 1)
            #expect(gains[0] > gains[1] + 0.4)
        }

        @Test("should boost skin less than a muted blue of the same chroma")
        func protectsSkin() {
            let skin = ColorSwatches.encoded(red: 224, green: 172, blue: 146)
            let blue = ColorSwatches.color(lightness: ColorSwatches.lab(skin).x, chroma: ColorSwatches.chroma(skin), hue: 250)
            let gains = VibranceTests.gain(amount: 100, for: [skin, blue])
            #expect(gains[0] < 1.35)
            #expect(gains[1] > gains[0] + 0.3)
        }

        @Test("should keep hue while boosting")
        func keepsHue() {
            let colors = stride(from: 0.0, to: 360, by: 30).map { ColorSwatches.color(lightness: 0.65, chroma: 0.06, hue: $0) }
            let output = ColorSwatches.apply(plugin: VibranceTests.plugin, values: ["vibrance": .number(100)], to: colors)
            for (input, boosted) in zip(colors, output) {
                #expect(abs(ColorSwatches.hueDistance(from: ColorSwatches.hue(boosted), to: ColorSwatches.hue(input))) < 0.5)
            }
        }

        @Test("should mute vivid colors more than muted ones at -100 without reaching gray")
        func mutes() {
            let muted = ColorSwatches.color(lightness: 0.6, chroma: 0.04, hue: 140)
            let vivid = ColorSwatches.color(lightness: 0.6, chroma: 0.15, hue: 140)
            let gains = VibranceTests.gain(amount: -100, for: [muted, vivid])
            #expect(gains.allSatisfy { $0 > 0.05 && $0 < 0.8 })
            #expect(gains[1] < gains[0])
        }
    }
}
