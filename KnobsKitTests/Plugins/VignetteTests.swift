import CoreImage
import Testing
@testable import KnobsKit

private enum Fixture {
    static func apply(_ image: CIImage, _ stored: [String: Double]) -> CIImage {
        let plugin = VignettePlugin()
        let values = KnobValues(params: plugin.params, stored: stored.mapValues { .number($0) })
        return plugin.apply(image: image, values: values, context: TestImages.context(for: image))
    }

    /// Red channel at a pixel, counted from the extent's bottom-left corner.
    static func value(_ image: CIImage, x: Int, y: Int) -> Float {
        let width = Int(image.extent.width)
        return Pixels.read(image)[(y * width + x) * 4]
    }
}

@Suite("VignettePlugin")
struct VignetteTests {
    @Suite("apply")
    struct Apply {
        @Test("should leave the image untouched at zero amount when the shape sliders moved")
        func amountZero() {
            let input = TestImages.gray(level: 0.3, size: 32)
            let output = Fixture.apply(input, ["midpoint": 10, "roundness": -60, "feather": 90, "highlights": 100])
            #expect(Pixels.maxDifference(between: output, and: input) == 0)
        }

        @Test("should darken the corners more than the center at a negative amount")
        func darkensCorners() {
            let input = TestImages.gray(level: 0.3, size: 64)
            let output = Fixture.apply(input, ["amount": -60])
            let center = Fixture.value(output, x: 32, y: 32)
            let corner = Fixture.value(output, x: 0, y: 0)
            #expect(abs(center - 0.3) < 1e-3)
            #expect(corner < 0.15)
        }

        @Test("should lighten the corners toward white at a positive amount")
        func lightensCorners() {
            let input = TestImages.gray(level: 0.3, size: 64)
            let output = Fixture.apply(input, ["amount": 60])
            #expect(Fixture.value(output, x: 63, y: 63) > 0.4)
            #expect(Fixture.value(output, x: 63, y: 63) <= 1)
        }

        @Test("should spare bright corners as Highlights rises")
        func sparesHighlights() {
            let input = TestImages.gray(level: 0.9, size: 64)
            let plain = Fixture.value(Fixture.apply(input, ["amount": -80]), x: 0, y: 0)
            let protected = Fixture.value(Fixture.apply(input, ["amount": -80, "highlights": 100]), x: 0, y: 0)
            #expect(protected > plain + 0.2)
        }

        @Test("should reach further toward the center at a lower midpoint")
        func midpointWidens() {
            let input = TestImages.gray(level: 0.3, size: 64)
            let wide = Fixture.value(Fixture.apply(input, ["amount": -60, "midpoint": 0]), x: 16, y: 32)
            let narrow = Fixture.value(Fixture.apply(input, ["amount": -60, "midpoint": 100]), x: 16, y: 32)
            #expect(wide < narrow - 0.05)
        }

        @Test("should follow the current extent after a crop moved its origin")
        func followsExtent() {
            let cropped = TestImages.gray(level: 0.3, size: 64)
                .cropped(to: CGRect(x: 16, y: 8, width: 40, height: 48))
            let output = Fixture.apply(cropped, ["amount": -60])
            #expect(output.extent == cropped.extent)
            let topLeft = Fixture.value(output, x: 0, y: 47)
            let bottomRight = Fixture.value(output, x: 39, y: 0)
            #expect(abs(topLeft - bottomRight) < 1e-3)
            #expect(abs(Fixture.value(output, x: 20, y: 24) - 0.3) < 1e-3)
        }
    }
}
