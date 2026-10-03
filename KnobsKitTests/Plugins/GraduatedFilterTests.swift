import CoreImage
import Testing
@testable import KnobsKit

@Suite("GraduatedFilterPlugin")
struct GraduatedFilterTests {
    static let plugin = GraduatedFilterPlugin()

    /// Mean red of one row; rows count from the top so they read like the unit coordinates.
    static func row(_ image: CIImage, fromTop row: Int) -> Float {
        let extent = image.extent
        let line = CGRect(x: extent.minX, y: extent.maxY - CGFloat(row) - 1, width: extent.width, height: 1)
        return Pixels.mean(image.cropped(to: line)).x
    }

    static func render(stored: [String: KnobValue]) -> CIImage {
        let input = TestImages.gray(level: 0.25, size: 64)
        let values = KnobValues(params: plugin.params, stored: stored)
        return plugin.apply(image: input, values: values, context: TestImages.context(for: input))
    }

    @Suite("adjustments")
    struct Adjustments {
        @Test("should map every adjustment to a param its plugin still has")
        func mapping() {
            for adjustment in GraduatedFilterPlugin.adjustments {
                for (own, target) in adjustment.params {
                    #expect(GraduatedFilterTests.plugin.param(own) != nil, "\(own)")
                    #expect(adjustment.plugin.param(target) != nil, "\(adjustment.plugin.id).\(target)")
                }
            }
        }
    }

    @Suite("apply")
    struct Apply {
        @Test("should leave the image alone when only the gradient moved")
        func onlyGradient() {
            let input = TestImages.gray(level: 0.25, size: 64)
            let output = GraduatedFilterTests.render(stored: [GraduatedGradient.Key.endY: .number(0.9)])
            #expect(Pixels.maxDifference(between: output, and: input) < 1e-4)
        }

        @Test("should apply fully before the start line and not at all past the end line")
        func fade() {
            let output = GraduatedFilterTests.render(stored: [
                "exposure": .number(1),
                GraduatedGradient.Key.startY: .number(0.2),
                GraduatedGradient.Key.endY: .number(0.6),
            ])
            #expect(abs(GraduatedFilterTests.row(output, fromTop: 2) - 0.5) < 2e-3)
            #expect(abs(GraduatedFilterTests.row(output, fromTop: 60) - 0.25) < 2e-3)
            let middle = GraduatedFilterTests.row(output, fromTop: 25)
            #expect(middle > 0.3 && middle < 0.45)
        }

        @Test("should follow the gradient's direction when drawn bottom to top")
        func direction() {
            let output = GraduatedFilterTests.render(stored: [
                "exposure": .number(-1),
                GraduatedGradient.Key.startY: .number(1),
                GraduatedGradient.Key.endY: .number(0.5),
            ])
            #expect(abs(GraduatedFilterTests.row(output, fromTop: 2) - 0.25) < 2e-3)
            #expect(GraduatedFilterTests.row(output, fromTop: 62) < 0.15)
        }
    }
}
