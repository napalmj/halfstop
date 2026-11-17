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
    /// - Parameter weights: a grayscale image over the measurement render (`measurementImage`'s extent):
    ///   only the pixels it covers count toward the average. Auto uses it to balance on the grayest
    ///   pixels; it's also the place to weight toward faces.
    static func whiteBalance(source: ImageSource, adjustments: Adjustments, region: CGRect?, weights: CIImage? = nil) -> WhiteBalance {
        var base = Adjustments()
        base.crop = adjustments.crop
        base.exposure = adjustments.exposure
        let renderScale = scale(source)
        // Temperature moves blue against red; tint moves green against red+blue. Both are zero when neutral.
        func error(_ x: SIMD2<Double>) -> SIMD2<Double> {
            var a = base
            a.temperature = x.x
            a.tint = x.y
            var image = source.developed(a, geometry: .full, renderScale: renderScale)
            if let weights {
                // Scaling every pixel by its weight scales the channel sums alike, so the ratios hold.
                image = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weights])
                    .cropped(to: image.extent)
            }
            let (r, g, b) = average(image, region: region)
            // A render with non-finite values says nothing about the cast: treat it as neutral
            // rather than let NaN steer the solve to the end of the range.
            guard r.isFinite, g.isFinite, b.isFinite else { return .zero }
            return SIMD2(log(max(b, 1e-6) / max(r, 1e-6)), log(max(g, 1e-6) / max((r * b).squareRoot(), 1e-6)))
        }
        let x = solveNeutral(error)
        return WhiteBalance(temperature: x.x.rounded() + 0, tint: x.y.rounded() + 0)
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

    /// Whites and blacks: where the ends of the range land.
    struct Levels: Equatable, Sendable {
        var whites: Double
        var blacks: Double
    }

    /// What kind of exposure a photo has, which decides how far auto pushes it.
    enum Scene: String, Equatable, Sendable {
        case normal
        /// Already fine: auto stays close to zero.
        case wellExposed
        /// Dark on purpose, with exposed highlights: not dragged up to middle gray.
        case lowKey
        /// Bright on purpose, with real darks: not dragged down to middle gray.
        case highKey
        /// A low-light scene with point lights: little shadow lift, no highlight recovery.
        case night
    }

    /// Medians in this band (sRGB-encoded) are a matter of taste: exposure leaves them alone.
    static let medianBand = 0.36...0.56

    /// Starts from the current white balance, otherwise from defaults.
    static func tone(source: ImageSource, adjustments: Adjustments) -> Tone {
        let inputs = AutoRequest(url: source.url, kind: .tone, adjustments: adjustments).inputs
        return compute(.tone, source: source, inputs: inputs).tone ?? Tone(exposure: 0, contrast: 0, highlights: 0, shadows: 0)
    }

    /// Nothing but black, or nothing but clipped white: there's no detail for tone, levels or the
    /// second opinion to work with, so auto leaves exposure and the tone sliders alone.
    static func isBlank(_ s: ImageStats) -> Bool {
        s.percentile(0.995) <= 1.0 / 255 || s.percentile(0.005) >= 254.0 / 255
    }

    static func scene(_ s: ImageStats) -> Scene {
        guard s.pixelCount > 16 else { return .normal }
        let median = s.percentile(0.5), lo = s.percentile(0.005), hi = s.percentile(0.995)
        let lights = s.fraction { $0 >= 0.85 }, clipped = s.fraction { $0 >= 0.98 }
        if median < 0.16, hi >= 0.8, lights < 0.03 { return .night }
        if median < 0.3, s.percentile(0.99) >= 0.7 { return .lowKey }
        if median > 0.6, s.percentile(0.05) < 0.3, clipped < 0.03 { return .highKey }
        if medianBand.contains(median), lo <= 0.08, hi >= 0.88, clipped < 0.01 { return .wellExposed }
        return .normal
    }

    /// Exposure from the median and how much room the highlights have, then contrast, highlights
    /// and shadows from the shifted distribution, each held back according to the scene.
    static func tone(_ s: ImageStats, scene: Scene) -> Tone {
        guard s.pixelCount > 16, !isBlank(s) else { return Tone(exposure: 0, contrast: 0, highlights: 0, shadows: 0) }
        let median = s.percentile(0.5), hi = s.percentile(0.995)
        func evTo(_ target: Double) -> Double { log2(linear(target) / max(linear(median), 1e-4)) }
        // To the nearest edge of the band; zero inside it.
        let toBand = median < medianBand.lowerBound ? evTo(medianBand.lowerBound)
            : median > medianBand.upperBound ? evTo(medianBand.upperBound) : 0
        // How far the top 0.5% could rise before reaching white.
        let headroom = log2(linear(0.96) / max(linear(hi), 1e-4))

        var ev: Double
        switch scene {
        case .night:
            ev = min(max(toBand * 0.2, -0.3), 0.3)
        case .lowKey:
            // The highlights are where they should be: never push them into clipping.
            ev = min(toBand * 0.35, max(headroom - 0.05, 0), 0.6)
        case .highKey:
            ev = max(toBand * 0.35, -0.4)
        case .wellExposed, .normal:
            if toBand >= 0 {
                // Dark: lift to the band, and when nothing reaches the highlights (an underexposed
                // frame), on toward the middle of it, without clipping more than the highlights can recover.
                ev = max(toBand, min(headroom - 0.2, evTo(0.45)))
                ev = min(ev, headroom + 0.3)
                ev = max(ev, 0)
            } else {
                ev = toBand
            }
        }
        ev = (min(max(ev, -3), 3) * 20).rounded() / 20   // 0.05 EV steps, like the slider
        let k = pow(2, ev)
        // Exposure is monotonic, so the shifted distribution is the same histogram with moved levels.
        func shifted(_ v: Double) -> Double { encoded(min(1, linear(v) * k)) }

        let blown = s.fraction { shifted($0) >= 0.97 }
        let dark = s.fraction { shifted($0) <= 0.06 }
        let spread = shifted(s.percentile(0.95)) - shifted(s.percentile(0.05))
        var contrast = spread < 0.6 ? (0.6 - spread) * 70 : spread > 0.88 ? -(spread - 0.88) * 80 : 0
        var highlights = -max(0, blown - 0.004) * 1500
        var shadows = max(0, dark - 0.02) * 300
        switch scene {
        case .night: highlights = 0; shadows = min(shadows * 0.25, 20); contrast = min(contrast, 10)
        case .lowKey: shadows *= 0.5; contrast = min(contrast, 15)
        case .highKey: highlights *= 0.5; contrast = min(contrast, 15)
        case .wellExposed: contrast *= 0.5; highlights *= 0.5; shadows *= 0.5
        case .normal: break
        }
        // (`+ 0` turns -0 into 0, so a slider never reads "-0".)
        return Tone(exposure: ev + 0,
                    contrast: min(max(contrast, -15), 30).rounded() + 0,
                    highlights: min(max(highlights, -70), 0).rounded() + 0,
                    shadows: min(max(shadows, 0), 50).rounded() + 0)
    }

    /// Whites and blacks that put the 99.5th and 0.5th percentiles (after `tone`) near the ends of
    /// the range, so it's used without clipping more than about 0.5%. Only ever stretches: a photo
    /// that already reaches black and white keeps zero.
    static func levels(_ s: ImageStats, tone: Tone, scene: Scene) -> Levels {
        guard s.pixelCount > 16, !isBlank(s) else { return Levels(whites: 0, blacks: 0) }
        let k = pow(2, tone.exposure)
        func shifted(_ v: Double) -> Double { encoded(min(1, linear(v) * k)) }
        let hi = shifted(s.percentile(0.995)), lo = shifted(s.percentile(0.005))
        var a = Adjustments()
        a.contrast = tone.contrast
        // Where a level lands through the real tone table (contrast, whites, blacks).
        func output(_ v: Double, whites: Double, blacks: Double) -> Double {
            a.whites = whites; a.blacks = blacks
            let table = ColorLUT.toneTable(ColorLUTKey(a), size: 256)
            let p = min(max(v, 0), 1) * 255
            let i = min(Int(p), 254)
            return Double(table[i]) + Double(table[i + 1] - table[i]) * (p - Double(i))
        }
        // Monotonic in the slider, so bisect for the slider value that lands `v` on `target`.
        func slider(_ range: ClosedRange<Double>, _ v: Double, _ target: Double, _ out: (Double) -> Double) -> Double {
            var lo = range.lowerBound, hi = range.upperBound
            let rising = out(hi) > out(lo)
            for _ in 0..<10 {
                let mid = (lo + hi) / 2
                if (out(mid) < target) == rising { lo = mid } else { hi = mid }
            }
            return ((lo + hi) / 2).rounded() + 0
        }
        var whites = 0.0, blacks = 0.0
        if scene != .night, scene != .highKey, hi < 0.93, output(hi, whites: 0, blacks: 0) < 0.95 {
            whites = slider(0...30, hi, 0.97) { output(hi, whites: $0, blacks: 0) }
        }
        if scene != .lowKey, lo > 0.06, output(lo, whites: whites, blacks: 0) > 0.04 {
            // A bright, airy photo keeps its soft darks.
            blacks = slider(scene == .highKey ? -15...0 : -30...0, lo, 0.03) { output(lo, whites: whites, blacks: $0) }
        }
        return Levels(whites: whites, blacks: blacks)
    }

    // MARK: Color

    struct ColorBoost: Equatable, Sendable {
        var vibrance: Double
        var saturation: Double
    }

    /// Mean perceptual chroma auto aims vibrance at: a typical, pleasantly colorful photo.
    static let targetChroma = 0.065

    /// Vibrance toward a typical colorfulness, held back when there's skin (or faces), and at most a
    /// light touch of saturation.
    static func color(_ s: ImageStats, hints: AutoHints = AutoHints()) -> ColorBoost {
        let mean = s.meanChroma
        // Black and white, or as good as (even its most colorful pixels are near gray): nothing to boost.
        guard s.pixelCount > 16, s.chromaPercentile(0.95) >= 0.012 else { return ColorBoost(vibrance: 0, saturation: 0) }
        var vibrance = (targetChroma - mean) / targetChroma * 30
        if vibrance > 0 {
            vibrance *= max(0.3, 1 - s.skinFraction * 2)
        } else {
            // Only rein in colors that are actually garish.
            vibrance = -max(0, s.chromaPercentile(0.9) - 0.22) * 100
        }
        var saturation = 0.0
        if hints.faces.isEmpty {
            if s.skinFraction < 0.05 { saturation = min(max(vibrance * 0.15, 0), 5) }
        } else {
            vibrance = min(vibrance * 0.5, 15)
        }
        return ColorBoost(vibrance: min(max(vibrance, -10), 25).rounded() + 0, saturation: saturation.rounded() + 0)
    }

    // MARK: Auto

    /// White balance, then tone, whites/blacks and vibrance measured with that white balance.
    /// Everything starts from defaults (only the crop is kept), so the result doesn't depend on the
    /// current sliders and pressing Auto again changes nothing.
    ///
    /// Faces (found with Vision on the as-shot measurement render, unless `hints` already gives
    /// them) keep skin from going green or magenta, pull exposure toward the faces, and hold
    /// vibrance back. Core Image's own auto-enhance suggestions are then read as a second opinion
    /// that nudges, but never replaces, these values.
    static func auto(source: ImageSource, inputs: Adjustments, hints given: AutoHints? = nil) -> AutoResult {
        var base = Adjustments()
        base.crop = inputs.crop
        var wb = WhiteBalance(temperature: 0, tint: 0)
        var hints = given ?? AutoHints()
        var asShotMean: SIMD3<Double>?
        if let asShot = readback(measurementImage(source, base)) {
            asShotMean = meanLinear(asShot)
            if given == nil { hints.faces = AutoVision.shared.faces(in: asShot, url: source.url) }
            if let weights = neutralWeights(asShot) {
                wb = whiteBalance(source: source, adjustments: base, region: nil, weights: weights)
            } else {
                // No convincing neutrals: the whole-frame average is only a guess (a sunset would turn
                // gray), so go half way, and not far.
                let g = whiteBalance(source: source, adjustments: base, region: nil)
                func half(_ v: Double) -> Double { (v * 0.5).clamped(to: -20...20).rounded() + 0 }
                wb = WhiteBalance(temperature: half(g.temperature), tint: half(g.tint))
            }
            if let mask = faceMask(hints.faces, like: asShot) {
                var balanced = base
                balanced.temperature = wb.temperature
                balanced.tint = wb.tint
                wb.tint = skinTint(source: source, adjustments: balanced, weights: weightImage(mask, like: asShot))
            }
        }
        var balanced = base
        balanced.temperature = wb.temperature
        balanced.tint = wb.tint
        guard let bm = readback(measurementImage(source, balanced)) else {
            return AutoResult(whiteBalance: wb, hints: hints, asShotMean: asShotMean)
        }
        let stats = ImageStats(bm)
        let scene = scene(stats)
        var tone = tone(stats, scene: scene)
        // Too few pixels, or nothing but black or white: tone measured nothing, so nothing nudges it either.
        let measurable = stats.pixelCount > 16 && !isBlank(stats)
        if measurable, let face = faceLuminance(bm, faces: hints.faces) {
            tone.exposure = faceExposure(tone.exposure, faceLuminance: face.luminance, faceArea: face.area, stats: stats, scene: scene)
        }
        var color = color(stats, hints: hints)
        let opinion = measurable ? secondOpinion(bm) : nil
        if let opinion {
            (tone, color) = nudged(tone, color, by: opinion, scene: scene, faces: !hints.faces.isEmpty)
        }
        return AutoResult(whiteBalance: wb, tone: tone, levels: levels(stats, tone: tone, scene: scene),
                          color: color, scene: scene, stats: stats, hints: hints, opinion: opinion, asShotMean: asShotMean)
    }

    /// Mean linear RGB of a render, from every other pixel each way.
    static func meanLinear(_ bm: Bitmap) -> SIMD3<Double> {
        let toLinear = linearTable
        var sum = SIMD3<Double>(0, 0, 0)
        var n = 0
        bm.pixels.withUnsafeBufferPointer { px in
            for y in stride(from: 0, to: bm.height, by: 2) {
                var i = y * bm.width * 4
                for _ in stride(from: 0, to: bm.width, by: 2) {
                    sum += SIMD3(toLinear[Int(px[i])], toLinear[Int(px[i + 1])], toLinear[Int(px[i + 2])])
                    n += 1
                    i += 8
                }
            }
        }
        return n > 0 ? sum / Double(n) : sum
    }

    /// Share of the well-exposed pixels auto white balance treats as neutral candidates.
    static let neutralShare = 0.06

    /// The grayest well-exposed pixels of an as-shot render (the least chromatic `neutralShare`, and
    /// only if they're close to neutral), as weights for `whiteBalance`. nil when too few qualify.
    static func neutralWeights(_ bm: Bitmap) -> CIImage? {
        let n = bm.width * bm.height
        guard n > 0 else { return nil }
        let toLinear = linearTable
        let binWidth = 0.0025, bins = 80
        var chroma = [Float](repeating: -1, count: n)
        var hist = [Int](repeating: 0, count: bins)
        var valid = 0
        bm.pixels.withUnsafeBufferPointer { px in
            for i in 0..<n {
                let r8 = px[i * 4], g8 = px[i * 4 + 1], b8 = px[i * 4 + 2]
                guard max(r8, g8, b8) < 250 else { continue }   // clipped: its color is unknown
                let lab = Oklab(toLinear[Int(r8)], toLinear[Int(g8)], toLinear[Int(b8)])
                guard lab.L > 0.25, lab.L < 0.95 else { continue }
                let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
                chroma[i] = Float(c)
                hist[min(Int(c / binWidth), bins - 1)] += 1
                valid += 1
            }
        }
        guard Double(valid) >= Double(n) * 0.05 else { return nil }
        var cumulative = 0, threshold = 0.0
        for (i, c) in hist.enumerated() {
            cumulative += c
            if Double(cumulative) >= Double(valid) * neutralShare { threshold = Double(i + 1) * binWidth; break }
        }
        threshold = min(threshold, 0.05)
        var mask = [UInt8](repeating: 0, count: n)
        var chosen = 0
        for i in 0..<n where chroma[i] >= 0 && Double(chroma[i]) <= threshold { mask[i] = 255; chosen += 1 }
        guard Double(chosen) >= Double(n) * 0.02 else { return nil }
        return weightImage(mask, like: bm)
    }

    /// A grayscale image laid over `bm`'s render, from one byte per pixel in the same row order.
    static func weightImage(_ mask: [UInt8], like bm: Bitmap) -> CIImage {
        // Both bitmaps store the top row first, so rows line up without flipping.
        CIImage(bitmapData: Data(mask), bytesPerRow: bm.width, size: CGSize(width: bm.width, height: bm.height),
                format: .L8, colorSpace: nil)
            .transformed(by: CGAffineTransform(translationX: bm.extent.minX, y: bm.extent.minY))
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
    /// `linear` of each 8-bit sRGB level, for reading measurement bitmaps.
    static let linearTable: [Double] = (0..<256).map { linear(Double($0) / 255) }
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

    /// 8-bit sRGB pixels of a measurement render, top row first.
    struct Bitmap {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        /// Where it sits in Core Image coordinates.
        var extent: CGRect
    }

    /// Renders `image` (it should be measurement-sized) into memory once.
    static func readback(_ image: CIImage) -> Bitmap? {
        let e = image.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0, w * h < 4_000_000 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        Render.background.render(image, toBitmap: &px, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: Render.sRGB)
        return Bitmap(pixels: px, width: w, height: h, extent: e)
    }

    /// Reads `image` back once and summarizes it: a luminance histogram (vImage), mean color, and
    /// chroma and skin-tone statistics.
    static func measure(_ image: CIImage) -> ImageStats? {
        readback(image).map(ImageStats.init)
    }
}

/// Extra knowledge about the photo for `AutoAdjust.auto`. Empty means none.
struct AutoHints: Equatable, Sendable {
    /// Face rectangles, normalized with a top-left origin in the cropped photo, largest first.
    /// With faces, white balance keeps skin tones natural, exposure leans toward the faces,
    /// vibrance is held back and saturation never raised. Filled by `AutoVision`.
    var faces: [CGRect] = []
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

    init(_ bm: AutoAdjust.Bitmap) {
        let px = bm.pixels, w = bm.width, h = bm.height
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
        let toLinear = AutoAdjust.linearTable
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
