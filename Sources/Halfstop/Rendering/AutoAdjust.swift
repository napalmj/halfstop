import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate

/// One-click starting points: white balance from a neutral spot (or the whole frame), and auto tone.
/// Everything is measured through the real develop pipeline, so it works the same for RAW and JPEG.
///
/// These functions are synchronous and touch the `ImageSource` they're given, which isn't
/// thread-safe: the app calls them only through `AutoEngine`, on its own queue and its own decode.
enum AutoAdjust {
    /// Long edge the measurements are taken at.
    static let measureSize: CGFloat = 512

    // MARK: White balance

    struct WhiteBalance: Equatable, Sendable {
        var temperature: Double
        var tint: Double
    }

    /// Temperature and tint that make the average color of `region` neutral gray.
    /// - Parameter region: normalized, top-left origin, in the cropped photo; nil = the whole frame (gray world).
    static func whiteBalance(source: ImageSource, adjustments: Adjustments, region: CGRect?) -> WhiteBalance {
        var base = Adjustments()
        base.crop = adjustments.crop
        base.exposure = adjustments.exposure
        let renderScale = scale(source)
        // Temperature moves blue against red; tint moves green against red+blue. Both are zero when neutral.
        func error(_ x: SIMD2<Double>) -> SIMD2<Double> {
            var a = base
            a.temperature = x.x
            a.tint = x.y
            let (r, g, b) = average(source.developed(a, geometry: .full, renderScale: renderScale), region: region)
            return SIMD2(log(max(b, 1e-6) / max(r, 1e-6)), log(max(g, 1e-6) / max((r * b).squareRoot(), 1e-6)))
        }
        let x = solveNeutral(error)
        return WhiteBalance(temperature: x.x.rounded(), tint: x.y.rounded())
    }

    static let sliderRange = -100.0...100.0
    /// Close enough to neutral: well under one slider step.
    static let neutralTolerance = 0.002
    /// Renders one white-balance solve may spend before giving up on Newton steps.
    static let maxNewtonRenders = 10

    /// Temperature and tint (each in -100...100) where `f` is zero.
    ///
    /// Each render costs a GPU round trip (a full RAW develop for RAW files), so this takes
    /// quasi-Newton (Broyden) steps from a finite-difference Jacobian, stopping as soon as the
    /// error is under tolerance: typically 4–6 renders. If that doesn't converge (a clipped or
    /// flat region), it falls back to alternating bisections, as before but with fewer steps.
    static func solveNeutral(_ f: (SIMD2<Double>) -> SIMD2<Double>) -> SIMD2<Double> {
        let lo = sliderRange.lowerBound, hi = sliderRange.upperBound
        func clamp(_ v: SIMD2<Double>) -> SIMD2<Double> { SIMD2(v.x.clamped(to: sliderRange), v.y.clamped(to: sliderRange)) }
        func small(_ e: SIMD2<Double>) -> Bool { abs(e.x) < neutralTolerance && abs(e.y) < neutralTolerance }

        var x = SIMD2<Double>(0, 0)
        var fx = f(x)
        if small(fx) { return x }
        let h = 8.0
        let fT = f(x + SIMD2(h, 0)), fN = f(x + SIMD2(0, h))
        // Columns: how the error moves per unit of temperature and of tint.
        var j0 = (fT - fx) / h, j1 = (fN - fx) / h
        var renders = 3
        while renders < maxNewtonRenders {
            let det = j0.x * j1.y - j1.x * j0.y
            guard abs(det) > 1e-9, det.isFinite else { break }
            // Solve J·dx = -fx.
            var dx = SIMD2((-fx.x * j1.y + fx.y * j1.x) / det, (-fx.y * j0.x + fx.x * j0.y) / det)
            let longest = max(abs(dx.x), abs(dx.y))
            if longest > 60 { dx *= 60 / longest }
            let xn = clamp(x + dx)
            let step = xn - x
            let fn = f(xn)
            renders += 1
            if small(fn) || max(abs(step.x), abs(step.y)) < 0.25 {
                // Converged, or pinned at the end of the range (the old bisection also returned the end).
                if max(abs(fn.x), abs(fn.y)) <= max(abs(fx.x), abs(fx.y)) || small(fn) { return xn }
                break
            }
            // Broyden update: J += ((Δf − J·Δx) ⊗ Δx) / |Δx|².
            let df = fn - fx
            let predicted = j0 * step.x + j1 * step.y
            let u = (df - predicted) / (step.x * step.x + step.y * step.y)
            j0 += u * step.x
            j1 += u * step.y
            x = xn
            fx = fn
        }

        // Fallback: each component is monotonic in its own slider, so alternate two bisections.
        var t = x.x, tn = x.y
        for _ in 0..<2 {
            t = solve(range: lo...hi) { v in f(SIMD2(v, tn)).x }
            tn = solve(range: lo...hi) { v in f(SIMD2(t, v)).y }
        }
        return SIMD2(t, tn)
    }

    /// Root of a monotonic function over `range` by bisection (an end of the range if it never crosses zero).
    static func solve(range: ClosedRange<Double>, _ f: (Double) -> Double) -> Double {
        var lo = range.lowerBound, hi = range.upperBound
        let flo = f(lo), fhi = f(hi)
        if flo.sign == fhi.sign { return abs(flo) < abs(fhi) ? lo : hi }
        let rising = fhi > flo
        for _ in 0..<9 {   // 200 / 2^9 < 0.5: finer than the rounded slider value
            let mid = (lo + hi) / 2
            if (f(mid) < 0) == rising { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    // MARK: Tone

    struct Tone: Equatable, Sendable {
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
        guard let stats = measure(measurementImage(source, a)) else { return Tone(exposure: 0, contrast: 0, highlights: 0, shadows: 0) }
        return tone(stats)
    }

    static func tone(_ stats: ImageStats) -> Tone {
        guard stats.pixelCount > 16 else { return Tone(exposure: 0, contrast: 0, highlights: 0, shadows: 0) }
        let median = stats.percentile(0.5)
        var ev = log2(linear(0.42) / max(linear(median), 1e-4))
        ev = (min(max(ev, -3), 3) / 0.05).rounded() * 0.05
        let k = pow(2, ev)
        // Exposure is monotonic, so the shifted distribution is the same histogram with moved levels.
        func shifted(_ v: Double) -> Double { encoded(min(1, linear(v) * k)) }

        let blown = stats.fraction { shifted($0) >= 0.97 }
        let dark = stats.fraction { shifted($0) <= 0.06 }
        let spread = shifted(stats.percentile(0.95)) - shifted(stats.percentile(0.05))
        return Tone(exposure: ev,
                    contrast: min(max((0.7 - spread) * 80, -20), 35).rounded(),
                    highlights: -min(blown * 1500, 70).rounded(),
                    shadows: min(dark * 300, 60).rounded())
    }

    // MARK: Measuring

    static func scale(_ source: ImageSource) -> CGFloat {
        min(1, measureSize / max(source.size.width, source.size.height, 1))
    }

    /// The photo developed with `a` at the measurement size (about 512 px long edge).
    static func measurementImage(_ source: ImageSource, _ a: Adjustments) -> CIImage {
        source.developed(a, geometry: .full, renderScale: scale(source))
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

    /// Reads `image` back once (it should be measurement-sized) and summarizes it: a luminance
    /// histogram (vImage), mean color, and chroma and skin-tone statistics.
    static func measure(_ image: CIImage) -> ImageStats? {
        let e = image.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0, w * h < 4_000_000 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        Render.background.render(image, toBitmap: &px, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: Render.sRGB)
        return ImageStats(rgba: px, width: w, height: h)
    }
}

/// What one measurement render of a photo looks like, in numbers. Everything auto decides is
/// derived from this, and later features (style learning, image info) can reuse it.
struct ImageStats: Equatable, Sendable {
    /// Pixel counts per sRGB-encoded luminance level 0...255 (Rec. 709 weights).
    var luminance: [Int]
    var pixelCount: Int
    /// Mean linear RGB.
    var meanRGB: SIMD3<Double>
    /// Perceptual chroma (Oklab) of a subsample of the pixels.
    var meanChroma: Double
    /// Counts per chroma bin of `chromaBinWidth`, the last bin catching everything above.
    var chroma: [Int]
    /// Share of the sampled pixels that look like skin.
    var skinFraction: Double

    static let chromaBinWidth = 0.005
    static let chromaBins = 80

    /// Luminance (sRGB-encoded, 0...1) below which `p` of the pixels fall, the same element a sorted
    /// list would give at index `(count - 1) * p`.
    func percentile(_ p: Double) -> Double {
        Double(Self.bin(luminance, total: pixelCount, p)) / 255
    }

    /// Chroma below which `p` of the sampled pixels fall (bin centers).
    func chromaPercentile(_ p: Double) -> Double {
        let total = chroma.reduce(0, +)
        return (Double(Self.bin(chroma, total: total, p)) + 0.5) * Self.chromaBinWidth
    }

    /// Share of pixels whose luminance level (0...1) satisfies `include`.
    func fraction(_ include: (Double) -> Bool) -> Double {
        guard pixelCount > 0 else { return 0 }
        var n = 0
        for (i, c) in luminance.enumerated() where c > 0 && include(Double(i) / 255) { n += c }
        return Double(n) / Double(pixelCount)
    }

    private static func bin(_ hist: [Int], total: Int, _ p: Double) -> Int {
        guard total > 0 else { return 0 }
        let index = Int(Double(total - 1) * min(max(p, 0), 1))
        var cumulative = 0
        for (i, c) in hist.enumerated() {
            cumulative += c
            if cumulative > index { return i }
        }
        return hist.count - 1
    }

    init(rgba px: [UInt8], width w: Int, height h: Int) {
        // Luminance histogram: a weighted channel sum into one plane, then vImage's histogram.
        var hist = [vImagePixelCount](repeating: 0, count: 256)
        var plane = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeBytes { src in
            plane.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: vImagePixelCount(h),
                                      width: vImagePixelCount(w), rowBytes: w * 4)
                var d = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                // Rec. 709 weights in 1/4096ths (summing to 4096), rounded to the nearest level.
                let matrix: [Int16] = [871, 2929, 296, 0]
                let preBias: [Int16] = [0, 0, 0, 0]
                vImageMatrixMultiply_ARGB8888ToPlanar8(&s, &d, matrix, 4096, preBias, 2048, vImage_Flags(kvImageNoFlags))
                hist.withUnsafeMutableBufferPointer { _ = vImageHistogramCalculation_Planar8(&d, $0.baseAddress!, vImage_Flags(kvImageNoFlags)) }
            }
        }
        luminance = hist.map { Int($0) }
        pixelCount = w * h

        // Color statistics from every other pixel in each direction: plenty for averages.
        var toLinear = [Double](repeating: 0, count: 256)
        for i in 0..<256 { toLinear[i] = AutoAdjust.linear(Double(i) / 255) }
        var sum = SIMD3<Double>(0, 0, 0)
        var chromaSum = 0.0, skin = 0, n = 0
        var chromaHist = [Int](repeating: 0, count: Self.chromaBins)
        for y in stride(from: 0, to: h, by: 2) {
            var i = y * w * 4
            for _ in stride(from: 0, to: w, by: 2) {
                let r = toLinear[Int(px[i])], g = toLinear[Int(px[i + 1])], b = toLinear[Int(px[i + 2])]
                sum += SIMD3(r, g, b)
                let lab = Oklab(r, g, b)
                let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
                chromaSum += c
                chromaHist[min(Int(c / Self.chromaBinWidth), Self.chromaBins - 1)] += 1
                if lab.looksLikeSkin { skin += 1 }
                n += 1
                i += 8
            }
        }
        let count = Double(max(n, 1))
        meanRGB = sum / count
        meanChroma = chromaSum / count
        chroma = chromaHist
        skinFraction = Double(skin) / count
    }
}

/// A perceptual color space (lightness L, opponent axes a and b), from linear sRGB.
struct Oklab {
    var L: Double, a: Double, b: Double

    init(_ r: Double, _ g: Double, _ bl: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// Skin of any complexion sits in a narrow band of warm hues with moderate chroma. Sand, wood and
    /// orange things land here too, which only makes vibrance a little more careful.
    var looksLikeSkin: Bool {
        let c = (a * a + b * b).squareRoot()
        guard L > 0.3, L < 0.93, c > 0.02, c < 0.17 else { return false }
        let hue = atan2(b, a) * 180 / .pi
        return hue > 25 && hue < 80
    }
}
