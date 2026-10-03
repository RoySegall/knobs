import CoreImage
import simd
import Foundation
import Testing
@testable import KnobsKit

@Suite("DehazePlugin")
struct DehazeTests {
    static let width = 256
    static let height = 160
    static let airlight = SIMD3<Float>(0.78, 0.81, 0.86)
    /// Rows above this are sky: pure airlight.
    static let horizon = 40
    /// Columns left of this are far (thick haze); the rest is near.
    static let depthEdge = 128

    /// Haze-free scene: colorful foliage-like texture whose dark channel is near zero, like real scenes.
    static func clean(x: Int, y: Int) -> SIMD3<Float> {
        let n = PresenceScene.noise(x: x / 3, y: y / 3)
        let fine = PresenceScene.noise(x: x, y: y, seed: 7)
        let base = SIMD3<Float>(0.10, 0.16, 0.03) * (0.4 + 1.2 * n)
        return base * (0.85 + 0.3 * fine)
    }

    static func transmission(x: Int, y: Int) -> Float {
        guard y >= horizon else { return 0 }
        return x < depthEdge ? 0.3 : 0.85
    }

    /// I = J·t + A·(1 − t), with a sky of pure airlight.
    static func hazy(exposure: Float = 1) -> CIImage {
        PresenceScene.make(width: width, height: height) { x, y in
            let t = transmission(x: x, y: y)
            return (clean(x: x, y: y) * t + airlight * (1 - t)) * exposure
        }
    }

    static func cleanImage() -> CIImage {
        PresenceScene.make(width: width, height: height) { x, y in
            y < horizon ? airlight : clean(x: x, y: y)
        }
    }

    /// Far region away from the depth edge and borders.
    static let farX = 12..<(depthEdge - 24)
    static let groundY = (horizon + 12)..<(height - 12)

    @Suite("apply")
    struct Apply {
        @Test("should leave an image that is all airlight unchanged")
        func uniform() {
            let input = PresenceScene.make(width: 96, height: 64) { _, _ in DehazeTests.airlight }
            for amount in [-100.0, 100] {
                let output = PresenceScene.apply(DehazePlugin(), amount: amount, to: input)
                #expect(Pixels.maxDifference(between: output, and: input) < 0.01)
            }
        }

        @Test("should keep pixels finite and non-negative on a near-black scene")
        func darkScene() {
            let input = PresenceScene.make(width: 96, height: 64) { x, y in
                SIMD3(0.002, 0.001, 0.0005) * (1 + PresenceScene.noise(x: x, y: y))
            }
            let output = Pixels.read(PresenceScene.apply(DehazePlugin(), amount: 100, to: input))
            #expect(output.allSatisfy { $0.isFinite && $0 >= 0 })

        }

        @Test("should not push pixels brighter than the airlight past white")
        func ceiling() {
            let input = PresenceScene.make(width: 96, height: 64) { x, _ in
                x < 48 ? DehazeTests.airlight : SIMD3(0.97, 0.95, 0.9)
            }
            let output = PresencePixels(PresenceScene.apply(DehazePlugin(), amount: 100, to: input))
            for x in 50..<94 {
                let c = output.rgb(x: x, y: 32)
                #expect(max(c.x, c.y, c.z) <= 1.0 + 1e-3)
            }
        }

        @Test("should leave the sky's color alone")
        func sky() {
            let input = DehazeTests.hazy()
            let output = PresencePixels(PresenceScene.apply(DehazePlugin(), amount: 100, to: input))
            let c = output.rgb(x: 128, y: 10)
            #expect(simd_length(c - DehazeTests.airlight) < 0.02)
        }

        @Test("should not leave a halo of haze beside a depth edge")
        func noHalo() {
            let output = PresencePixels(PresenceScene.apply(DehazePlugin(), amount: 100, to: DehazeTests.hazy()))
            let edge = DehazeTests.depthEdge
            let besideEdge = PresencePixels.mean(output.lumas(x: (edge - 6)..<(edge - 2), y: DehazeTests.groundY))
            let awayFromEdge = PresencePixels.mean(output.lumas(x: (edge - 40)..<(edge - 36), y: DehazeTests.groundY))
            #expect(abs(besideEdge - awayFromEdge) < 0.04)
        }

        @Test("should raise local contrast in a hazy region and move it toward the clean scene")
        func removesHaze() {
            let input = DehazeTests.hazy()
            let output = PresencePixels(PresenceScene.apply(DehazePlugin(), amount: 100, to: input))
            let hazy = PresencePixels(input)
            let clean = PresencePixels(DehazeTests.cleanImage())
            let before = PresencePixels.deviation(hazy.lumas(x: DehazeTests.farX, y: DehazeTests.groundY))
            let after = PresencePixels.deviation(output.lumas(x: DehazeTests.farX, y: DehazeTests.groundY))
            #expect(after > 1.8 * before)

            var errorBefore: Float = 0
            var errorAfter: Float = 0
            for y in DehazeTests.groundY {
                for x in DehazeTests.farX {
                    errorBefore += abs(hazy.luma(x: x, y: y) - clean.luma(x: x, y: y))
                    errorAfter += abs(output.luma(x: x, y: y) - clean.luma(x: x, y: y))
                }
            }
            #expect(errorAfter < 0.5 * errorBefore)
        }

        @Test("should dehaze far regions more than near ones")
        func depthAware() {
            let input = DehazeTests.hazy()
            let output = PresencePixels(PresenceScene.apply(DehazePlugin(), amount: 100, to: input))
            let hazy = PresencePixels(input)
            let nearX = (DehazeTests.depthEdge + 24)..<(DehazeTests.width - 12)
            func change(_ x: Range<Int>) -> Float {
                PresencePixels.mean(hazy.lumas(x: x, y: DehazeTests.groundY))
                    - PresencePixels.mean(output.lumas(x: x, y: DehazeTests.groundY))
            }
            #expect(change(DehazeTests.farX) > 2 * change(nearX))
        }

        @Test("should add haze at negative values")
        func addsHaze() {
            let input = DehazeTests.cleanImage()
            let output = PresencePixels(PresenceScene.apply(DehazePlugin(), amount: -100, to: input))
            let clean = PresencePixels(input)
            let ground = 0..<DehazeTests.width
            let before = PresencePixels.deviation(clean.lumas(x: ground, y: DehazeTests.groundY))
            let after = PresencePixels.deviation(output.lumas(x: ground, y: DehazeTests.groundY))
            #expect(after < 0.7 * before)
            let brightening = PresencePixels.mean(output.lumas(x: ground, y: DehazeTests.groundY))
                - PresencePixels.mean(clean.lumas(x: ground, y: DehazeTests.groundY))
            #expect(brightening > 0.1)
        }

        @Test("should scale with exposure, so the airlight estimate follows the image")
        func exposureInvariant() {
            let plain = Pixels.read(PresenceScene.apply(DehazePlugin(), amount: 70, to: DehazeTests.hazy()))
            let bright = Pixels.read(PresenceScene.apply(DehazePlugin(), amount: 70, to: DehazeTests.hazy(exposure: 2)))
            var difference: Float = 0
            var total: Float = 0
            for index in stride(from: 0, to: plain.count, by: 4) {
                for channel in 0..<3 {
                    difference += abs(bright[index + channel] / 2 - plain[index + channel])
                    total += plain[index + channel]
                }
            }
            #expect(difference < 0.03 * total)
        }

        @Test("should look the same in a half-size preview as in the downscaled export")
        func previewMatchesExport() {
            let input = DehazeTests.hazy()
            let export = PresenceScene.apply(DehazePlugin(), amount: 100, to: input)
            let small = GuidedFilter.downsample(input, scale: 0.5)
            let preview = PresencePixels(PresenceScene.apply(DehazePlugin(), amount: 100, to: small, scale: 0.5))
            let exportSmall = PresencePixels(GuidedFilter.downsample(export, scale: 0.5))
            let original = PresencePixels(small)
            var mismatch: Float = 0
            var effect: Float = 0
            for y in 8..<72 {
                for x in 8..<120 {
                    mismatch += abs(preview.luma(x: x, y: y) - exportSmall.luma(x: x, y: y))
                    effect += abs(exportSmall.luma(x: x, y: y) - original.luma(x: x, y: y))
                }
            }
            #expect(mismatch < 0.25 * effect)
        }
    }
}
