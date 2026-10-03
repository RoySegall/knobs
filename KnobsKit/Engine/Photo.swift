import CoreImage
import UniformTypeIdentifiers

public struct Photo: Sendable {
    public enum Source: Sendable {
        /// Kept as bytes so every render gets a fresh decoder; CIRAWFilter is mutable and not Sendable.
        case raw(data: Data, typeIdentifier: String)
        case bitmap(CIImage)
    }

    public enum LoadError: Error {
        case unreadable(URL)
    }

    public let url: URL
    public let source: Source
    public let fullSize: CGSize

    public static let fileExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp",
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq", "x3f",
    ]

    public static func load(url: URL) throws -> Photo {
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .rawImage) {
            let data = try Data(contentsOf: url)
            guard let filter = CIRAWFilter(imageData: data, identifierHint: type.identifier),
                  let image = filter.outputImage
            else { throw LoadError.unreadable(url) }
            return Photo(url: url, source: .raw(data: data, typeIdentifier: type.identifier), fullSize: image.extent.size)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw LoadError.unreadable(url)
        }
        let origin = image.extent.origin
        let normalized = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        return Photo(url: url, source: .bitmap(normalized), fullSize: normalized.extent.size)
    }

    public init(url: URL, source: Source, fullSize: CGSize) {
        self.url = url
        self.source = source
        self.fullSize = fullSize
    }

    public var sourceKind: RenderContext.Source {
        switch source {
        case .raw: .raw
        case .bitmap: .bitmap
        }
    }

    func makeRAWFilter() -> CIRAWFilter? {
        guard case .raw(let data, let typeIdentifier) = source else { return nil }
        return CIRAWFilter(imageData: data, identifierHint: typeIdentifier)
    }
}
