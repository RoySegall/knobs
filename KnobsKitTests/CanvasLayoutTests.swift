import CoreGraphics
import Testing
@testable import KnobsKit

@Suite("CanvasLayout")
struct CanvasLayoutTests {
    @Suite("fit")
    struct Fit {
        @Test("should give an empty frame for an empty image")
        func empty() {
            let layout = CanvasLayout.fit(imageSize: .zero, drawableSize: CGSize(width: 800, height: 600), padding: 20)
            #expect(layout.frame == .zero)
        }

        @Test("should draw 1:1 when the image fits within 1%")
        func oneToOne() {
            let layout = CanvasLayout.fit(imageSize: CGSize(width: 955, height: 694), drawableSize: CGSize(width: 1000, height: 740), padding: 20)
            #expect(layout.scale == 1)
            #expect(layout.frame.size == CGSize(width: 955, height: 694))
        }

        @Test("should scale a larger image down and keep its aspect")
        func scalesDown() {
            let layout = CanvasLayout.fit(imageSize: CGSize(width: 2000, height: 1000), drawableSize: CGSize(width: 1040, height: 1040), padding: 20)
            #expect(layout.scale == 0.5)
            #expect(layout.frame == CGRect(x: 20, y: 270, width: 1000, height: 500))
        }

        @Test("should center the image on whole pixels")
        func wholePixels() {
            let layout = CanvasLayout.fit(imageSize: CGSize(width: 999, height: 600), drawableSize: CGSize(width: 1040, height: 1040), padding: 20)
            #expect(layout.frame.minX == layout.frame.minX.rounded())
            #expect(layout.frame.minY == layout.frame.minY.rounded())
            #expect(abs(layout.frame.midX - 520) <= 0.5)
        }
    }

    @Suite("view mapping")
    struct ViewMapping {
        let layout = CanvasLayout.fit(imageSize: CGSize(width: 400, height: 300), drawableSize: CGSize(width: 1000, height: 800), padding: 20)

        @Test("should flip Core Image's bottom-left frame into view points")
        func viewFrame() {
            let frame = CanvasLayout(scale: 1, frame: CGRect(x: 100, y: 50, width: 400, height: 300), drawableSize: CGSize(width: 1000, height: 800))
                .viewFrame(pixelsPerPoint: 2)
            #expect(frame == CGRect(x: 50, y: 225, width: 200, height: 150))
        }

        @Test("should put the image's top-left corner at the view frame's top-left")
        func topLeft() {
            let view = layout.viewFrame(pixelsPerPoint: 2)
            #expect(layout.viewPoint(unit: .zero, pixelsPerPoint: 2) == view.origin)
            #expect(layout.viewPoint(unit: CGPoint(x: 1, y: 1), pixelsPerPoint: 2) == CGPoint(x: view.maxX, y: view.maxY))
        }

        @Test("should round-trip a point between the image and the view")
        func roundTrip() {
            let unit = CGPoint(x: 0.3, y: 0.85)
            let back = layout.unitPoint(view: layout.viewPoint(unit: unit, pixelsPerPoint: 2), pixelsPerPoint: 2)
            #expect(abs(back.x - unit.x) < 1e-12 && abs(back.y - unit.y) < 1e-12)
        }
    }
}
