import Accelerate
import CoreImage
import ImageIO

/// Fitting a `CameraLook` to the camera's embedded JPEG: the curve by matching the two luminance
/// histograms, the color by least squares on pixels that line up.
extension CameraLook {
    /// Long side of the two images the fit compares.
    static let fitSize = 192
    /// The embedded preview is decoded no larger than this; JPEG decoders scale down nearly for free.
    static let previewSize = 256
    /// A preview smaller than this on its long side carries too little to fit.
    static let minimumPreview = 64

    /// The look for a RAW whose neutral decode is `decode`: fitted to the embedded preview, or the fallback.
    static func measure(decode: CIImage, data: Data, typeIdentifier: String, clipLevel: Float, context: CIContext) -> CameraLook {
        guard let preview = embeddedPreview(data: data, typeIdentifier: typeIdentifier) else { return .fallback }
        return measure(decode: decode, preview: CIImage(cgImage: preview), clipLevel: clipLevel, context: context) ?? .fallback
    }

    /// The camera's own JPEG, upright. Only an image embedded in the file, never one rendered from the RAW.
    static func embeddedPreview(data: Data, typeIdentifier: String) -> CGImage? {
        let hint = [kCGImageSourceTypeIdentifierHint: typeIdentifier] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, hint) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Nil when the preview is too small to fit or doesn't describe the decode. A preview with another
    /// aspect (a 16:9 setting on a 3:2 sensor) is matched to the decode's center.
    static func measure(decode: CIImage, preview: CIImage, clipLevel: Float, context: CIContext) -> CameraLook? {
        let frame = withoutBars(preview, context: context)
        let longSide = max(frame.width, frame.height)
        guard longSide >= CGFloat(minimumPreview), frame.height >= 1 else { return nil }
        let aspect = frame.width / frame.height
        let side = min(CGFloat(fitSize), longSide.rounded(.down))
        let size = aspect >= 1
            ? CGSize(width: side, height: max(1, (side / aspect).rounded()))
            : CGSize(width: max(1, (side * aspect).rounded()), height: side)
        let ours = pixels(resampled(decode, from: centered(in: decode.extent, aspect: aspect), to: size), context: context)
        let camera = pixels(resampled(preview, from: frame, to: size), context: context)
        return fit(ours: ours, camera: camera, clipLevel: clipLevel)
    }

    /// Fits the look that takes `ours`, the neutral decode, to `camera`, the camera's rendering of the same
    /// frame. Both are linear sRGB RGBA floats, pixel for pixel. Nil when they share too little to fit.
    static func fit(ours: [Float], camera: [Float], clipLevel: Float, white: Float = RenderEngine.rawWhite) -> CameraLook? {
        let count = min(ours.count, camera.count) / 4
        guard count >= 256 else { return nil }
        let oursLuma = luminance(ours, count: count)
        let cameraLuma = luminance(camera, count: count)
        let pairs = quantilePairs(ours: oursLuma, target: cameraLuma)
        guard let first = levels(pairs: pairs, white: white) else { return nil }
        var look = CameraLook(levels: first, origin: .preview)

        // Color needs the two images to line up pixel for pixel; the curve only needs their histograms.
        let aligned = correlation(table: ToneTable(look: look), ours: ours, camera: camera, count: count) >= 0.9
        func refitColor() {
            guard aligned else { return }
            let matrix = colorMatrix(table: ToneTable(look: look), ours: ours, camera: camera, count: count, clipLevel: clipLevel)
            look = CameraLook(levels: look.levels, matrix: matrix, origin: .preview)
        }
        refitColor()

        // Colored pixels don't land exactly on the curve (it bends their brightest and darkest channel),
        // so one more pass moves each quantile's target by what the render still misses.
        let table = ToneTable(look: look)
        let rendered = renderedLuminance(table: table, matrix: look.matrix, ours: ours, count: count)
        let misses = quantilePairs(ours: rendered, target: cameraLuma)
        let corrected = zip(pairs, misses).map { pair, miss in
            guard pair.1 > minimumTarget, pair.1 < maximumTarget else { return (pair.0, Float.nan) }
            return (pair.0, linear(gamma(table(pair.0)) + gamma(miss.1) - gamma(miss.0)))
        }
        if let second = levels(pairs: corrected, white: white) {
            look = CameraLook(levels: second, matrix: look.matrix, origin: .preview)
            refitColor()
        }
        return isPlausible(look) ? look : nil
    }

    // MARK: Curve

    /// Camera values outside this band are crushed or clipped and say nothing about the curve's shape.
    static let minimumTarget: Float = 0.002
    static let maximumTarget: Float = 0.93

    /// Equal-rank pairs of two samples: the curve that matches their histograms passes through them.
    static func quantilePairs(ours: [Float], target: [Float], count: Int = 256) -> [(Float, Float)] {
        let sortedOurs = sorted(ours)
        let sortedTarget = sorted(target)
        return (0..<count).map { k in
            let rank = (Float(k) + 0.5) / Float(count)
            let x = sortedOurs[min(sortedOurs.count - 1, Int(rank * Float(sortedOurs.count)))]
            let y = sortedTarget[min(sortedTarget.count - 1, Int(rank * Float(sortedTarget.count)))]
            return (x, y)
        }
    }

    /// Knot levels through (scene-linear, display-linear) pairs. Inside the pairs' range the curve follows
    /// them, smoothed in stops and gamma; below it runs proportionally to black; above it a shoulder with
    /// the data's slope lands on white at `white`. Nil when the pairs span less than two stops.
    static func levels(pairs: [(Float, Float)], white: Float) -> [Float]? {
        var stops: [Float] = []
        var gammas: [Float] = []
        for (x, y) in pairs where x > exp2(lowStop) && y > minimumTarget && y < maximumTarget {
            let stop = log2(x)
            let encoded = gamma(y)
            if let last = stops.last, stop - last < 1e-3 {
                gammas[gammas.count - 1] = max(gammas[gammas.count - 1], encoded)
            } else if encoded >= gammas.last ?? 0 {
                stops.append(stop)
                gammas.append(encoded)
            }
        }
        guard stops.count >= 8, let low = stops.first, let high = stops.last, high - low >= 2 else { return nil }

        var knots = [Float](repeating: .nan, count: knotCount)
        var segment = 0
        for knot in 0..<knotCount {
            let stop = Self.stop(knot: knot)
            guard stop >= low, stop <= high else { continue }
            while segment < stops.count - 2, stops[segment + 1] < stop {
                segment += 1
            }
            let width = max(stops[segment + 1] - stops[segment], 1e-6)
            let fraction = min(max((stop - stops[segment]) / width, 0), 1)
            knots[knot] = gammas[segment] + (gammas[segment + 1] - gammas[segment]) * fraction
        }
        guard let first = knots.firstIndex(where: { !$0.isNaN }), let last = knots.lastIndex(where: { !$0.isNaN }),
              last - first >= 4
        else { return nil }
        for _ in 0..<3 {
            let previous = knots
            for knot in (first + 1)..<last {
                knots[knot] = 0.25 * previous[knot - 1] + 0.5 * previous[knot] + 0.25 * previous[knot + 1]
            }
        }

        var levels = knots.map { $0.isNaN ? $0 : linear($0) }
        for knot in stride(from: first - 1, through: 0, by: -1) {
            levels[knot] = levels[first] * exp2(stop(knot: knot) - stop(knot: first))
        }
        let end = exp2(stop(knot: last))
        let endLevel = levels[last]
        let before = exp2(stop(knot: last - 2))
        let room = 1 - endLevel
        let reach = white - end
        // The data's slope where it ends, raised if needed so the shoulder still reaches white.
        var slope = max((endLevel - levels[last - 2]) / (end - before), 0)
        if reach > 0, slope * reach < room {
            slope = room / reach
        }
        let bend = reach > 0 && room > 0 ? max(1 / room - 1 / (slope * reach), 0) : 0
        for knot in (last + 1)..<knotCount {
            let over = exp2(stop(knot: knot)) - end
            levels[knot] = over >= reach ? 1 : min(1, endLevel + slope * over / (1 + slope * over * bend))
        }
        for knot in 1..<knotCount {
            levels[knot] = min(1, max(levels[knot], levels[knot - 1] + 1e-5))
        }
        return levels.allSatisfy(\.isFinite) && levels[0] > 0 ? levels : nil
    }

    /// Mid-gray lands somewhere a camera would put it; anything else means the preview isn't this photo.
    static func isPlausible(_ look: CameraLook) -> Bool {
        let gray = gamma(ToneTable(look: look)(0.18))
        return (0.12...0.8).contains(gray) && look.matrix.allSatisfy(\.isFinite)
    }

    // MARK: Color

    static let lumaWeights: (Float, Float, Float) = (0.2126, 0.7152, 0.0722)
    /// Ridge toward the identity, per fitted pixel.
    static let ridge: Float = 0.02
    /// Largest move of each matrix coordinate, so a scene of one hue can't swing the others far.
    static let matrixLimit: Float = 0.3

    /// A 3×3 that keeps white and luminance, fitted so the curve applied to `matrix · ours` lands on the
    /// camera's colors. Compared at equal luminance, so only chroma and hue drive it. Four degrees of
    /// freedom: each of the first two rows moves in the plane that keeps it summing to one, along
    /// (1, -1, 0) and (1, 1, -2), and the third row follows to keep luminance.
    static func colorMatrix(table: ToneTable, ours: [Float], camera: [Float], count: Int, clipLevel: Float) -> [Float] {
        let (y0, y1, y2) = lumaWeights
        let root2 = Float(2).squareRoot()
        let root6 = Float(6).squareRoot()
        let p = -y0 / y2
        let q = -y1 / y2
        // Normal equations reduce to these sums, because each basis matrix has one free row.
        var aa: Float = 0, ac: Float = 0, cc: Float = 0
        var targetA0: Float = 0, targetC0: Float = 0, targetA1: Float = 0, targetC1: Float = 0
        var along: Float = 0, spread: Float = 0
        var used = 0
        table.read { tone in
            ours.withUnsafeBufferPointer { ours in
                camera.withUnsafeBufferPointer { camera in
                    for pixel in 0..<count {
                        let index = pixel * 4
                        let (r, g, b) = (ours[index], ours[index + 1], ours[index + 2])
                        let (cr, cg, cb) = (camera[index], camera[index + 1], camera[index + 2])
                        guard min(cr, cg, cb) > 0.004, max(cr, cg, cb) < maximumTarget,
                              min(r, g, b) > 0, max(r, g, b) < 0.9 * clipLevel
                        else { continue }
                        let luma = y0 * r + y1 * g + y2 * b
                        guard luma > exp2(-9), let tr = tone.inverse(cr), let tg = tone.inverse(cg), let tb = tone.inverse(cb)
                        else { continue }
                        let targetLuma = y0 * tr + y1 * tg + y2 * tb
                        let (or, og, ob) = (r / luma, g / luma, b / luma)
                        let (dr, dg, db) = (tr / targetLuma - or, tg / targetLuma - og, tb / targetLuma - ob)
                        let a = (or - og) / root2
                        let c = (or + og - 2 * ob) / root6
                        aa += a * a
                        ac += a * c
                        cc += c * c
                        targetA0 += a * (dr + p * db)
                        targetC0 += c * (dr + p * db)
                        targetA1 += a * (dg + q * db)
                        targetC1 += c * (dg + q * db)
                        let (sr, sg, sb) = (or - 1, og - 1, ob - 1)
                        along += sr * (sr + dr) + sg * (sg + dg) + sb * (sb + db)
                        spread += sr * sr + sg * sg + sb * sb
                        used += 1
                    }
                }
            }
        }
        // A camera set to monochrome (or a preview with no color to compare) keeps the decode's color.
        guard used >= 200, spread > 0, along / spread > 0.3 else { return identityMatrix }
        let first = 1 + p * p
        let second = 1 + q * q
        let cross = p * q
        let damping = ridge * Float(used)
        let normal: [Float] = [
            first * aa + damping, first * ac, cross * aa, cross * ac,
            first * ac, first * cc + damping, cross * ac, cross * cc,
            cross * aa, cross * ac, second * aa + damping, second * ac,
            cross * ac, cross * cc, second * ac, second * cc + damping,
        ]
        guard let theta = solve(normal: normal, target: [targetA0, targetC0, targetA1, targetC1]) else { return identityMatrix }
        let t = theta.map { min(max($0, -matrixLimit), matrixLimit) }
        let red = (t[0] / root2 + t[1] / root6, -t[0] / root2 + t[1] / root6, -2 * t[1] / root6)
        let green = (t[2] / root2 + t[3] / root6, -t[2] / root2 + t[3] / root6, -2 * t[3] / root6)
        return [
            1 + red.0, red.1, red.2,
            green.0, 1 + green.1, green.2,
            p * red.0 + q * green.0, p * red.1 + q * green.1, 1 + p * red.2 + q * green.2,
        ]
    }

    /// Gaussian elimination with partial pivoting on a small dense system.
    static func solve(normal: [Float], target: [Float]) -> [Float]? {
        let n = target.count
        var a = normal
        var b = target
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0 * n + column]) < abs(a[$1 * n + column]) }),
                  abs(a[pivot * n + column]) > 1e-12
            else { return nil }
            if pivot != column {
                for k in 0..<n {
                    a.swapAt(pivot * n + k, column * n + k)
                }
                b.swapAt(pivot, column)
            }
            for row in (column + 1)..<n {
                let factor = a[row * n + column] / a[column * n + column]
                for k in column..<n {
                    a[row * n + k] -= factor * a[column * n + k]
                }
                b[row] -= factor * b[column]
            }
        }
        var x = [Float](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n {
                sum -= a[row * n + k] * x[k]
            }
            x[row] = sum / a[row * n + row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    // MARK: Pixels

    static func luminance(_ pixels: [Float], count: Int) -> [Float] {
        var (y0, y1, y2) = lumaWeights
        var result = [Float](repeating: 0, count: count)
        pixels.withUnsafeBufferPointer { pixels in
            result.withUnsafeMutableBufferPointer { result in
                guard let source = pixels.baseAddress, let out = result.baseAddress else { return }
                let length = vDSP_Length(count)
                vDSP_vsmul(source, 4, &y0, out, 1, length)
                vDSP_vsma(source + 1, 4, &y1, out, 1, out, 1, length)
                vDSP_vsma(source + 2, 4, &y2, out, 1, out, 1, length)
            }
        }
        return result
    }

    static func renderedLuminance(table: ToneTable, matrix: [Float], ours: [Float], count: Int) -> [Float] {
        let (y0, y1, y2) = lumaWeights
        var result = [Float](repeating: 0, count: count)
        table.read { tone in
            matrix.withUnsafeBufferPointer { matrix in
                ours.withUnsafeBufferPointer { ours in
                    result.withUnsafeMutableBufferPointer { result in
                        for pixel in 0..<count {
                            let index = pixel * 4
                            let (r, g, b) = tone.render(red: ours[index], green: ours[index + 1], blue: ours[index + 2], matrix: matrix)
                            result[pixel] = y0 * r + y1 * g + y2 * b
                        }
                    }
                }
            }
        }
        return result
    }

    /// Pearson correlation of rendered and camera luminance in gamma: near 1 when the frames line up.
    static func correlation(table: ToneTable, ours: [Float], camera: [Float], count: Int) -> Float {
        let rendered = renderedLuminance(table: table, matrix: identityMatrix, ours: ours, count: count).map(gamma)
        let target = luminance(camera, count: count).map(gamma)
        let x = vDSP.add(-vDSP.mean(rendered), rendered)
        let y = vDSP.add(-vDSP.mean(target), target)
        let xx = vDSP.dot(x, x)
        let yy = vDSP.dot(y, y)
        return xx > 0 && yy > 0 ? vDSP.dot(x, y) / (xx * yy).squareRoot() : 0
    }

    static func sorted(_ values: [Float]) -> [Float] {
        var copy = values
        vDSP_vsort(&copy, vDSP_Length(copy.count), 1)
        return copy
    }

    /// The preview's extent less black letterbox bars, trimmed evenly so the frame stays centered.
    static func withoutBars(_ preview: CIImage, context: CIContext) -> CGRect {
        let extent = preview.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return extent }
        let values = pixels(preview, context: context)
        let (y0, y1, y2) = lumaWeights
        func dark(_ pixel: Int) -> Bool {
            y0 * values[pixel * 4] + y1 * values[pixel * 4 + 1] + y2 * values[pixel * 4 + 2] < 0.0015
        }
        func darkRun(lines: Int, length: Int, pixel: (Int, Int) -> Int, reversed: Bool) -> Int {
            let limit = lines / 6
            var run = 0
            while run < limit {
                let line = reversed ? lines - 1 - run : run
                guard (0..<length).allSatisfy({ dark(pixel(line, $0)) }) else { break }
                run += 1
            }
            return run
        }
        let rows = min(
            darkRun(lines: height, length: width, pixel: { $0 * width + $1 }, reversed: false),
            darkRun(lines: height, length: width, pixel: { $0 * width + $1 }, reversed: true)
        )
        let columns = min(
            darkRun(lines: width, length: height, pixel: { $1 * width + $0 }, reversed: false),
            darkRun(lines: width, length: height, pixel: { $1 * width + $0 }, reversed: true)
        )
        return extent.insetBy(dx: CGFloat(columns), dy: CGFloat(rows))
    }

    static func centered(in extent: CGRect, aspect: CGFloat) -> CGRect {
        if extent.width / extent.height > aspect {
            let width = extent.height * aspect
            return CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
        }
        let height = extent.width / aspect
        return CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
    }

    static func resampled(_ image: CIImage, from rect: CGRect, to size: CGSize) -> CIImage {
        image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / rect.width, y: size.height / rect.height), highQualityDownsample: true)
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Linear sRGB RGBA floats.
    static func pixels(_ image: CIImage, context: CIContext) -> [Float] {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        values.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: space)
        }
        return values
    }
}
