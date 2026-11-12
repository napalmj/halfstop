import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// One-click starting points: white balance from a neutral spot (or the whole frame), and auto tone.
/// Everything is measured through the real develop pipeline, so it works the same for RAW and JPEG.
enum AutoAdjust {
    /// Long edge the measurements are taken at.
    static let measureSize: CGFloat = 512

    // MARK: White balance

    /// Temperature and tint that make the average color of `region` neutral gray.
    /// - Parameter region: normalized, top-left origin, in the cropped photo; nil = the whole frame (gray world).
    static func whiteBalance(source: ImageSource, adjustments: Adjustments, region: CGRect?) -> (temperature: Double, tint: Double) {
        var base = Adjustments()
        base.crop = adjustments.crop
        base.exposure = adjustments.exposure
        func color(_ temperature: Double, _ tint: Double) -> (Double, Double, Double) {
            var a = base
            a.temperature = temperature
            a.tint = tint
            return average(source.developed(a, geometry: .full, renderScale: scale(source)), region: region)
        }
        // Temperature moves blue against red; tint moves green against red+blue.
        // Each is monotonic in its own slider, so alternate two bisections.
        var t = adjustments.temperature, tn = adjustments.tint
        for _ in 0..<3 {
            t = solve(range: -100...100) { v in let (r, _, b) = color(v, tn); return log(max(b, 1e-6) / max(r, 1e-6)) }
            tn = solve(range: -100...100) { v in let (r, g, b) = color(t, v); return log(max(g, 1e-6) / max((r * b).squareRoot(), 1e-6)) }
        }
        return (t.rounded(), tn.rounded())
    }

    /// Root of a monotonic function over `range` by bisection (an end of the range if it never crosses zero).
    static func solve(range: ClosedRange<Double>, _ f: (Double) -> Double) -> Double {
        var lo = range.lowerBound, hi = range.upperBound
        let flo = f(lo), fhi = f(hi)
        if flo.sign == fhi.sign { return abs(flo) < abs(fhi) ? lo : hi }
        let rising = fhi > flo
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if (f(mid) < 0) == rising { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    // MARK: Tone

    struct Tone: Equatable {
        var exposure: Double
        var contrast: Double
        var highlights: Double
        var shadows: Double
    }

    /// Exposure to put the median near middle gray, then highlights/shadows/contrast from how much
    /// of the frame sits at the ends and how spread out it is. Starts from the current white balance.
    static func tone(source: ImageSource, adjustments: Adjustments) -> Tone {
        var a = Adjustments()
        a.crop = adjustments.crop
        a.temperature = adjustments.temperature
        a.tint = adjustments.tint
        let lum = luminances(source.developed(a, geometry: .full, renderScale: scale(source)))
        guard lum.count > 16 else { return Tone(exposure: 0, contrast: 0, highlights: 0, shadows: 0) }
        func pct(_ v: [Double], _ p: Double) -> Double { v[min(v.count - 1, Int(Double(v.count - 1) * p))] }

        let median = pct(lum, 0.5)
        var ev = log2(linear(0.42) / max(linear(median), 1e-4))
        ev = (min(max(ev, -3), 3) / 0.05).rounded() * 0.05
        let k = pow(2, ev)
        let shifted = lum.map { encoded(min(1, linear($0) * k)) }

        let blown = Double(shifted.filter { $0 >= 0.97 }.count) / Double(shifted.count)
        let dark = Double(shifted.filter { $0 <= 0.06 }.count) / Double(shifted.count)
        let spread = pct(shifted, 0.95) - pct(shifted, 0.05)
        return Tone(exposure: ev,
                    contrast: min(max((0.7 - spread) * 80, -20), 35).rounded(),
                    highlights: -min(blown * 1500, 70).rounded(),
                    shadows: min(dark * 300, 60).rounded())
    }

    // MARK: Helpers

    private static func scale(_ source: ImageSource) -> CGFloat {
        min(1, measureSize / max(source.size.width, source.size.height, 1))
    }

    static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encoded(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    /// Linear average color of a region (normalized, top-left origin).
    static func average(_ image: CIImage, region: CGRect?) -> (Double, Double, Double) {
        let e = image.extent
        var box = e
        if let r = region {
            box = CGRect(x: e.minX + r.minX * e.width, y: e.minY + (1 - r.maxY) * e.height,
                         width: max(r.width * e.width, 2), height: max(r.height * e.height, 2)).intersection(e)
        }
        guard !box.isEmpty else { return (0, 0, 0) }
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: box)])
        var p = [Float](repeating: 0, count: 4)
        Render.background.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 format: .RGBAf, colorSpace: nil)
        return (Double(p[0]), Double(p[1]), Double(p[2]))
    }

    /// Sorted sRGB-encoded luminance of every pixel.
    static func luminances(_ image: CIImage) -> [Double] {
        let e = image.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0, w * h < 4_000_000 else { return [] }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        Render.background.render(image, toBitmap: &px, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: Render.sRGB)
        var out = [Double]()
        out.reserveCapacity(w * h)
        for i in stride(from: 0, to: px.count, by: 4) {
            out.append((0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255)
        }
        return out.sorted()
    }
}
