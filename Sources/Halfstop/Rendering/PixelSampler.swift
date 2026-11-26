import Foundation
import CoreImage

/// Reads developed pixels for the photo tools (the color under a click, a patch for spot removal).
/// Renders small regions only, so it's quick enough to run on a click. Not thread-safe (the
/// `ImageSource` isn't): call it where the source is used, on the main thread.
enum PixelSampler {
    /// Long edge the photo is developed at for sampling.
    static let workingSize: CGFloat = 1200

    /// The developed image for sampling, scaled down, with its scale.
    private static func image(_ source: ImageSource, _ a: Adjustments, geometry: GeometryMode) -> CIImage {
        let scale = min(1, workingSize / max(source.size.width, source.size.height, 1))
        return source.developed(a, geometry: geometry, renderScale: scale)
    }

    /// Average display color (sRGB, 0...1) in a small square around `p` (normalized, top-left
    /// origin, in the space `geometry` shows).
    static func color(_ source: ImageSource, _ a: Adjustments, geometry: GeometryMode, at p: NormPoint, radius: Double = 0.004) -> SIMD3<Float>? {
        let img = image(source, a, geometry: geometry)
        let e = img.extent
        guard !e.isEmpty, e.width.isFinite else { return nil }
        let r = max(1, CGFloat(radius) * max(e.width, e.height))
        let c = CGPoint(x: e.minX + p.x * e.width, y: e.minY + (1 - p.y) * e.height)
        let box = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2).intersection(e)
        guard !box.isEmpty,
              let avg = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: img, kCIInputExtentKey: CIVector(cgRect: box)])?.outputImage
        else { return nil }
        var px = [Float](repeating: 0, count: 4)
        Render.background.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 format: .RGBAf, colorSpace: Render.sRGB)
        return SIMD3(min(max(px[0], 0), 1), min(max(px[1], 0), 1), min(max(px[2], 0), 1))
    }

    /// Picks where to copy from for a spot at `center` with `radius` (fraction of the long edge),
    /// in the uncropped frame: the nearby patch whose surroundings best match the spot's own,
    /// preferring smooth patches (they rarely carry another blemish).
    static func spotSource(_ source: ImageSource, _ a: Adjustments, center: NormPoint, radius: Double) -> NormPoint {
        let fallback = NormPoint(x: center.x + radius * 2.5, y: center.y)
        let img = image(source, a, geometry: .none)
        let e = img.extent
        guard !e.isEmpty, e.width.isFinite else { return fallback }
        let longEdge = max(e.width, e.height)
        let r = max(2, CGFloat(radius) * longEdge)
        // Work on a small grid: the search region resampled so the spot is ~8 px across.
        let k = min(1, 8 / (r * 2))
        let reach = r * 4.5
        let c = CGPoint(x: center.x * e.width, y: (1 - center.y) * e.height)
        let region = CGRect(x: c.x - reach - r, y: c.y - reach - r, width: (reach + r) * 2, height: (reach + r) * 2)
        let small = img.clampedToExtent().cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        let w = Int((region.width * k).rounded(.up)), h = Int((region.height * k).rounded(.up))
        guard w > 4, h > 4, w * h < 400_000 else { return fallback }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.background.render(small, toBitmap: &px, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                 format: .RGBAf, colorSpace: Render.sRGB)
        // Bitmap rows run top to bottom; CI's y runs bottom to top.
        func at(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let xx = min(max(x, 0), w - 1), yy = min(max(h - 1 - y, 0), h - 1)
            let i = (yy * w + xx) * 4
            return SIMD3(px[i], px[i + 1], px[i + 2])
        }
        let sr = Double(r * k)
        // A ring just outside the spot, and the inside, as offsets.
        var ring: [(Int, Int)] = [], inside: [(Int, Int)] = []
        let ri = Int(ceil(sr * 1.5))
        for dy in -ri...ri {
            for dx in -ri...ri {
                let d = (Double(dx * dx + dy * dy)).squareRoot()
                if d <= sr { inside.append((dx, dy)) } else if d <= sr * 1.5 { ring.append((dx, dy)) }
            }
        }
        let cx = Int(((c.x - region.minX) * k).rounded()), cy = Int(((c.y - region.minY) * k).rounded())
        let target = ring.map { at(cx + $0.0, cy + $0.1) }
        var best: (score: Float, x: Int, y: Int)?
        for distance in [2.4, 3.2, 4.2] {
            for step in 0..<16 {
                let angle = Double(step) / 16 * 2 * .pi
                let x = cx + Int((cos(angle) * distance * sr).rounded()), y = cy + Int((sin(angle) * distance * sr).rounded())
                // Stay inside the photo.
                let fx = region.minX + CGFloat(x) / k, fy = region.minY + CGFloat(y) / k
                guard fx - r >= e.minX, fx + r <= e.maxX, fy - r >= e.minY, fy + r <= e.maxY else { continue }
                var diff: Float = 0
                for (i, o) in ring.enumerated() {
                    let d = at(x + o.0, y + o.1) - target[i]
                    diff += (d * d).sum()
                }
                diff /= Float(max(ring.count, 1))
                var mean = SIMD3<Float>(repeating: 0)
                for o in inside { mean += at(x + o.0, y + o.1) }
                mean /= Float(max(inside.count, 1))
                var variance: Float = 0
                for o in inside { let d = at(x + o.0, y + o.1) - mean; variance += (d * d).sum() }
                variance /= Float(max(inside.count, 1))
                // A slight preference for nearby patches.
                let score = diff + variance * 0.6 + Float(distance) * 0.0004
                if best == nil || score < best!.score { best = (score, x, y) }
            }
        }
        guard let best else { return fallback }
        let fx = region.minX + CGFloat(best.x) / k, fy = region.minY + CGFloat(best.y) / k
        return NormPoint(x: Double(fx / e.width), y: Double(1 - fy / e.height))
    }
}
