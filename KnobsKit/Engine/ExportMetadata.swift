import CoreGraphics
import Foundation
import ImageIO

/// The original's metadata, made true for the export.
enum ExportMetadata {
    /// Camera and copyright fields only; the rest of a RAW's TIFF block describes the sensor data.
    private static var tiffKeys: [CFString] {
        [
            kCGImagePropertyTIFFMake,
            kCGImagePropertyTIFFModel,
            kCGImagePropertyTIFFDateTime,
            kCGImagePropertyTIFFArtist,
            kCGImagePropertyTIFFCopyright,
            kCGImagePropertyTIFFImageDescription,
        ]
    }

    /// EXIF, GPS, IPTC and the camera's TIFF fields. Orientation is 1 because the pixels are already
    /// upright, and the size fields describe the export.
    static func properties(from source: URL, size: CGSize) -> [CFString: Any] {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
        else { return properties }

        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
            if let value = original[key] {
                properties[key] = value
            }
        }
        if var exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = Int(size.width)
            exif[kCGImagePropertyExifPixelYDimension] = Int(size.height)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        var tiff = (original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:])
            .filter { tiffKeys.contains($0.key) }
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFSoftware] = "Knobs"
        properties[kCGImagePropertyTIFFDictionary] = tiff
        return properties
    }
}
