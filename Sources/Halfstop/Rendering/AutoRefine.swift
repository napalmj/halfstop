import Foundation
import CoreImage

/// Refinements to ✦ Auto from what Apple's frameworks see in the photo (faces, Core Image's own
/// auto-enhance suggestions), and Auto straighten from the horizon. All pure decisions on
/// measurements, except `skinTint`, which re-renders like the white-balance solve.
extension AutoAdjust {
    // MARK: Faces

    /// The middle of a face box: skin, without the hair and background around it.
    static func faceCore(_ r: CGRect) -> CGRect { r.insetBy(dx: r.width * 0.2, dy: r.height * 0.2) }

    /// One byte per pixel over `bm` (same row order), 255 inside the faces' cores. nil without faces.
    static func faceMask(_ faces: [CGRect], like bm: Bitmap) -> [UInt8]? {
        guard !faces.isEmpty, bm.width > 0, bm.height > 0 else { return nil }
        var mask = [UInt8](repeating: 0, count: bm.width * bm.height)
        var any = false
        for f in faces {
            let c = faceCore(f)
            let x0 = max(0, Int(c.minX * Double(bm.width))), x1 = min(bm.width, Int((c.maxX * Double(bm.width)).rounded(.up)))
            let y0 = max(0, Int(c.minY * Double(bm.height))), y1 = min(bm.height, Int((c.maxY * Double(bm.height)).rounded(.up)))
            guard x1 > x0, y1 > y0 else { continue }
            for y in y0..<y1 { for x in x0..<x1 { mask[y * bm.width + x] = 255 } }
            any = true
        }
        return any ? mask : nil
    }

    /// Mean sRGB-encoded luminance of the faces' cores in a render, and how much of the frame the
    /// faces cover. nil without faces.
    static func faceLuminance(_ bm: Bitmap, faces: [CGRect]) -> (luminance: Double, area: Double)? {
        guard let mask = faceMask(faces, like: bm) else { return nil }
        let toLinear = linearTable
        var sum = 0.0, n = 0
        bm.pixels.withUnsafeBufferPointer { px in
            for i in 0..<mask.count where mask[i] != 0 {
                sum += 0.2126 * toLinear[Int(px[i * 4])] + 0.7152 * toLinear[Int(px[i * 4 + 1])] + 0.0722 * toLinear[Int(px[i * 4 + 2])]
                n += 1
            }
        }
        guard n > 0 else { return nil }
        let area = faces.reduce(0.0) { $0 + Double($1.width * $1.height) }
        return (encoded(sum / Double(n)), min(area, 1))
    }

    /// Face brightness (sRGB-encoded) that reads well: exposure leaves faces inside it alone.
    static let faceBand = 0.42...0.64

    /// Exposure leaned toward bringing faces into `faceBand`: more for bigger faces, never far
    /// from the scene's own choice, never into clipping, and not at all for night scenes.
    static func faceExposure(_ ev: Double, faceLuminance face: Double, faceArea: Double, stats s: ImageStats, scene: Scene) -> Double {
        guard scene != .night, face > 0.005 else { return ev }
        let shifted = encoded(min(1, linear(face) * pow(2, ev)))
        guard !faceBand.contains(shifted) else { return ev }
        let edge = shifted < faceBand.lowerBound ? faceBand.lowerBound : faceBand.upperBound
        let faceEV = log2(linear(edge) / max(linear(face), 1e-4))
        let weight = min(max(0.35 + faceArea * 2, 0.35), 0.7)
        let reach = scene == .lowKey || scene == .highKey ? 0.3 : 0.5
        var out = ev + min(max((faceEV - ev) * weight, -reach), reach)
        // Brighter only as far as the highlights can take (the same limit tone uses).
        let headroom = log2(linear(0.96) / max(linear(s.percentile(0.995)), 1e-4))
        if out > ev { out = min(out, max(ev, headroom + 0.3)) }
        return (min(max(out, -3), 3) * 20).rounded() / 20 + 0
    }

    /// Hues (Oklab, degrees) skin of any complexion falls in under neutral light.
    static let skinHue = 32.0...75.0
    /// How far a face may move the tint from the neutral solution.
    static let maxSkinTintShift = 10.0

    /// Tint that keeps the faces (`weights`) from looking green or magenta: unchanged when their
    /// hue is already in `skinHue`, otherwise moved (at most `maxSkinTintShift`) toward the
    /// nearest edge of it, by bisection through the real develop pipeline.
    static func skinTint(source: ImageSource, adjustments a: Adjustments, weights: CIImage) -> Double {
        let renderScale = scale(source)
        func face(_ tint: Double) -> Oklab {
            var b = a
            b.tint = tint
            let image = source.developed(b, geometry: .full, renderScale: renderScale)
            let weighted = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weights])
                .cropped(to: image.extent)
            let (r, g, bl) = average(weighted, region: nil)
            return Oklab(r, g, bl)
        }
        func hue(_ lab: Oklab) -> Double { atan2(lab.b, lab.a) * 180 / .pi }
        let start = face(a.tint)
        // Weighting scales the average, and Oklab scales L, a and b alike, so hue and chroma/L hold.
        let chroma = (start.a * start.a + start.b * start.b).squareRoot()
        guard start.L > 1e-4, chroma / start.L >= 0.04 else { return a.tint }   // gray (or B&W) faces: nothing to say
        let h = hue(start)
        guard !skinHue.contains(h) else { return a.tint }
        let target = h < skinHue.lowerBound ? skinHue.lowerBound : skinHue.upperBound
        let lo = max(a.tint - maxSkinTintShift, sliderRange.lowerBound), hi = min(a.tint + maxSkinTintShift, sliderRange.upperBound)
        return solve(range: lo...hi) { hue(face($0)) - target }.rounded() + 0
    }

    // MARK: Second opinion

    /// What Core Image's auto-enhance would do to the white-balanced measurement render, on the
    /// app's slider scales. nil parts weren't suggested.
    struct SecondOpinion: Equatable, Sendable {
        /// Midtone shift its tone curve implies, in EV.
        var exposure: Double?
        var vibrance: Double?
        var shadows: Double?
        var highlights: Double?
    }

    /// Asks `CIImage.autoAdjustmentFilters` (red-eye, crop and level off; no face detection, since
    /// faces are handled above) and translates its filters. The filters are never added to the
    /// pipeline: the sliders stay the single source of truth.
    static func secondOpinion(_ bm: Bitmap) -> SecondOpinion? {
        guard bm.width > 0, bm.height > 0 else { return nil }
        let filters = bm.ciImage.autoAdjustmentFilters(options: [.redEye: false, .features: [], .crop: false, .level: false])
        var o = SecondOpinion()
        for f in filters {
            switch f.name {
            case "CIToneCurve":
                let points = (0..<5).compactMap { (f.value(forKey: "inputPoint\($0)") as? CIVector).map { CGPoint(x: $0.x, y: $0.y) } }
                if let mid = curveValue(points, at: 0.5), mid > 0.001 {
                    o.exposure = min(max(log2(linear(mid) / linear(0.5)), -1.5), 1.5)
                }
            case "CIVibrance":
                if let v = (f.value(forKey: kCIInputAmountKey) as? NSNumber)?.doubleValue, v.isFinite { o.vibrance = v * 100 }
            case "CIHighlightShadowAdjust":
                // The same filter and scales the Shadows and Highlights sliders use.
                if let s = (f.value(forKey: "inputShadowAmount") as? NSNumber)?.doubleValue, s.isFinite { o.shadows = s * 100 }
                if let h = (f.value(forKey: "inputHighlightAmount") as? NSNumber)?.doubleValue, h.isFinite { o.highlights = (h - 1) * 100 }
            default:
                break
            }
        }
        return o == SecondOpinion() ? nil : o
    }

    /// A piecewise-linear curve's value at `x` (points sorted by x).
    static func curveValue(_ points: [CGPoint], at x: Double) -> Double? {
        let p = points.sorted { $0.x < $1.x }
        guard let first = p.first, let last = p.last else { return nil }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for i in 1..<p.count where x <= p[i].x {
            let a = p[i - 1], b = p[i]
            return b.x > a.x ? a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x) : b.y
        }
        return last.y
    }

    /// How much of the gap to the second opinion ✦ Auto closes.
    static let opinionShare = 0.25

    /// Our values moved a quarter of the way toward the second opinion, each step capped small.
    /// Well-exposed photos aren't nudged (they stay close to zero), exposure is nudged only for
    /// ordinary scenes (low-key, high-key and night photos keep their deliberate limits), night
    /// scenes keep their highlights and shadows, and with faces vibrance can only go down.
    static func nudged(_ tone: Tone, _ color: ColorBoost, by o: SecondOpinion, scene: Scene, faces: Bool) -> (Tone, ColorBoost) {
        guard scene != .wellExposed else { return (tone, color) }
        var t = tone, c = color
        func step(_ ours: Double, _ theirs: Double?, cap: Double) -> Double {
            guard let theirs else { return 0 }
            return min(max((theirs - ours) * opinionShare, -cap), cap)
        }
        if scene == .normal {
            t.exposure = ((t.exposure + step(t.exposure, o.exposure, cap: 0.15)) * 20).rounded() / 20 + 0
        }
        if scene != .night {
            t.shadows = (t.shadows + step(t.shadows, o.shadows, cap: 8)).clamped(to: 0...50).rounded() + 0
            t.highlights = (t.highlights + step(t.highlights, o.highlights, cap: 8)).clamped(to: -70...0).rounded() + 0
        }
        var dv = step(c.vibrance, o.vibrance, cap: 5)
        if faces { dv = min(dv, 0) }
        c.vibrance = (c.vibrance + dv).clamped(to: -10...25).rounded() + 0
        return (t, c)
    }

    // MARK: Straighten

    /// Auto straighten only acts on a horizon Vision is at least this sure of…
    static let minHorizonConfidence = 0.5
    /// …and only when it's tilted at most this much (degrees). Steeper lines are usually not the horizon.
    static let maxStraighten = 10.0

    /// The Straighten value for a detected horizon, rounded like the slider; nil when it shouldn't act.
    static func straightenAngle(_ h: AutoVision.Horizon?) -> Double? {
        guard let h, h.angle.isFinite, h.confidence >= minHorizonConfidence, abs(h.angle) <= maxStraighten else { return nil }
        return (h.angle * 10).rounded() / 10 + 0
    }

    /// Finds the horizon on an uncropped, unrotated render of up to 1024 px (the measurement
    /// decode at its own size), so the angle is absolute, whatever the current crop.
    static func straighten(source: ImageSource) -> AutoResult {
        let k = min(1, AutoEngine.decodeSize / max(source.size.width, source.size.height, 1))
        let image = source.developed(Adjustments(), geometry: .none, renderScale: k)
        guard let bm = readback(image), let cg = bm.cgImage else { return AutoResult() }
        let horizon = AutoVision.shared.horizon(in: cg, url: source.url)
        return AutoResult(angle: straightenAngle(horizon), horizon: horizon)
    }
}
