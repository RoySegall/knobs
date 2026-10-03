import CoreImage
import Foundation
import Testing
@testable import KnobsKit

@Suite("PreviewSession")
struct PreviewSessionTests {
    @Suite("image")
    struct Image {
        @Test("should keep pixels where they were after caching the base on the GPU")
        func keepsOrientation() {
            let input = TestImages.withinWhite()
            let photo = Photo(url: URL(fileURLWithPath: "/tmp/detail.png"), source: .bitmap(input), fullSize: input.extent.size)
            let session = RenderEngine(plugins: []).previewSession(photo: photo, maxPixelSize: TestImages.width)
            let output = session.image(document: EditDocument(), skipping: [])
            #expect(output.extent == input.extent)
            #expect(Pixels.maxDifference(between: output, and: input) < 2e-3)
        }
    }
}

@Suite("PhotoAnalysis")
struct PhotoAnalysisTests {
    @Suite("measure")
    struct Measure {
        @Test("should report white as the clip level of a bitmap")
        func bitmap() {
            let image = TestImages.gray(level: 0.5)
            #expect(PhotoAnalysis.measure(source: .bitmap(image), fullSize: image.extent.size).clipLevel == 1)
        }
    }
}
