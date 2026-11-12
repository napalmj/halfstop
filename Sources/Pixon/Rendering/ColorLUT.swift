import Foundation
import CoreImage

/// Bakes contrast / whites / blacks / positive highlights / tone curve / HSL into a single
/// 3D lookup table, so all of it costs one GPU pass no matter how many sliders are moved.
enum ColorLUT {
    static let dimension = 48

    private static let cache: NSCache<KeyBox, NSData> = {
        let c = NSCache<KeyBox, NSData>()
        c.countLimit = 64
        return c
    }()

    private final class KeyBox: NSObject {
        let key: ColorLUTKey
        init(_ key: ColorLUTKey) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
    }

    static func cubeData(for key: ColorLUTKey) -> Data {
        let box = KeyBox(key)
        if let cached = cache.object(forKey: box) { return cached as Data }
        let data = build(key)
        cache.setObject(data as NSData, forKey: box)
        return data
    }

    // MARK: - Tone

    /// 1D tone table (sRGB-encoded in, sRGB-encoded out).
    static func toneTable(_ key: ColorLUTKey, size: Int = 1024) -> [Float] {
        let curve = MonotoneCurve(points: key.curve)
        let contrastK = pow(2.0, key.contrast / 100.0 * 1.2)
        let whites = key.whites / 100.0
        let blacks = key.blacks / 100.0
        let highlights = key.highlights / 100.0

        var table = [Float](repeating: 0, count: size)
        for i in 0..<size {
            var v = Double(i) / Double(size - 1)
            // Blacks: move the dark end without touching the brights.
            v += blacks * 0.2 * pow(1 - v, 3)
            // Whites: move the bright end without touching the darks.
            v += whites * 0.2 * pow(v, 3)
            // Positive highlights (negative is handled by the local highlight/shadow filter).
            v += highlights * 0.25 * v * v * (1 - v) * 2
            v = min(max(v, 0), 1)
            // Contrast: symmetric S-curve around middle gray that never clips.
            if contrastK != 1 {
                v = v < 0.5 ? 0.5 * pow(2 * v, contrastK) : 1 - 0.5 * pow(2 * (1 - v), contrastK)
            }
            v = curve.evaluate(v)
            table[i] = Float(min(max(v, 0), 1))
        }
        return table
    }

    // MARK: - Cube

    private static func build(_ key: ColorLUTKey) -> Data {
        let n = dimension
        let tone = toneTable(key)
        let toneMax = Float(tone.count - 1)
        @inline(__always) func applyTone(_ x: Float) -> Float {
            let p = x * toneMax
            let i = min(Int(p), tone.count - 2)
            let f = p - Float(i)
            return tone[i] + (tone[i + 1] - tone[i]) * f
        }

        let hslActive = !key.hsl.allSatisfy(\.isNeutral)
        let grade = GradePrep(key.grading)
        let bands = key.hsl
        let centers = HSLColor.allCases.map { Float($0.centerHue) }

        var cube = [Float](repeating: 0, count: n * n * n * 4)
        let scale = 1 / Float(n - 1)
        cube.withUnsafeMutableBufferPointer { buf in
            var idx = 0
            for b in 0..<n {
                for g in 0..<n {
                    for r in 0..<n {
                        var rr = applyTone(Float(r) * scale)
                        var gg = applyTone(Float(g) * scale)
                        var bb = applyTone(Float(b) * scale)
                        if hslActive {
                            (rr, gg, bb) = applyHSL(rr, gg, bb, bands: bands, centers: centers)
                        }
                        if let grade {
                            (rr, gg, bb) = grade.apply(rr, gg, bb)
                        }
                        buf[idx] = rr
                        buf[idx + 1] = gg
                        buf[idx + 2] = bb
                        buf[idx + 3] = 1
                        idx += 4
                    }
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Weight of each band at a hue: raised-cosine falloff reaching zero at the neighboring
    /// band centers, so weights always sum to 1 and there are no seams between colors.
    private static func bandWeights(hue: Float, centers: [Float]) -> [(Int, Float)] {
        let count = centers.count
        var result: [(Int, Float)] = []
        for i in 0..<count {
            let c = centers[i]
            let prev = centers[(i + count - 1) % count]
            let next = centers[(i + 1) % count]
            let widthBelow = wrapDistance(c, prev)
            let widthAbove = wrapDistance(next, c)
            var d = hue - c
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            let width = d >= 0 ? widthAbove : widthBelow
            let ad = abs(d)
            if ad < width {
                result.append((i, 0.5 * (1 + cos(Float.pi * ad / width))))
            }
        }
        return result
    }

    private static func wrapDistance(_ a: Float, _ b: Float) -> Float {
        var d = a - b
        while d < 0 { d += 360 }
        while d >= 360 { d -= 360 }
        return d
    }

    private static func applyHSL(_ r: Float, _ g: Float, _ b: Float, bands: [HSLBand], centers: [Float]) -> (Float, Float, Float) {
        var (h, s, l) = rgbToHSL(r, g, b)
        if s < 0.0001 { return (r, g, b) }
        var dh: Float = 0, ds: Float = 0, dl: Float = 0
        for (i, w) in bandWeights(hue: h, centers: centers) {
            let band = bands[i]
            dh += w * Float(band.hue)
            ds += w * Float(band.saturation)
            dl += w * Float(band.luminance)
        }
        // Gray-ish pixels barely respond, like Lightroom.
        let satWeight = min(1, s * 2.5)
        h += dh / 100 * 30 * satWeight
        if h < 0 { h += 360 }
        if h >= 360 { h -= 360 }
        s = min(1, max(0, s * (1 + ds / 100 * satWeight)))
        l = min(1, max(0, l + dl / 100 * 0.25 * satWeight * (1 - abs(2 * l - 1) * 0.5)))
        return hslToRGB(h, s, l)
    }

    /// Precomputed color-grading wheel offsets.
    struct GradePrep {
        let tints: [(Float, Float, Float)]  // chroma offset per wheel (shadows, mids, highs)
        let lums: [Float]
        let shadowEnd: Float
        let highlightStart: Float

        init?(_ g: ColorGrading) {
            guard !g.isNeutral else { return nil }
            func tint(_ w: GradeWheel) -> (Float, Float, Float) {
                let (r, g, b) = ColorLUT.hslToRGB(Float(w.hue), 1, 0.5)
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let k = Float(w.saturation / 100) * 0.35
                return ((r - y) * k, (g - y) * k, (b - y) * k)
            }
            tints = [tint(g.shadows), tint(g.midtones), tint(g.highlights)]
            lums = [g.shadows, g.midtones, g.highlights].map { Float($0.luminance / 100) * 0.2 }
            let shift = Float(g.balance / 100) * 0.25
            shadowEnd = 0.55 + shift
            highlightStart = 0.45 + shift
        }

        @inline(__always) private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }

        func apply(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let ws = 1 - smoothstep(0, shadowEnd, y)
            let wh = smoothstep(highlightStart, 1, y)
            let wm = max(0, 1 - ws - wh)
            let w = [ws, wm, wh]
            var rr = r, gg = g, bb = b
            for i in 0..<3 where w[i] > 0 {
                rr += (tints[i].0 + lums[i]) * w[i]
                gg += (tints[i].1 + lums[i]) * w[i]
                bb += (tints[i].2 + lums[i]) * w[i]
            }
            return (min(max(rr, 0), 1), min(max(gg, 0), 1), min(max(bb, 0), 1))
        }
    }

    private static func rgbToHSL(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        if d == 0 { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Float
        if maxC == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if maxC == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h * 60, s, l)
    }

    fileprivate static func hslToRGB(_ h: Float, _ s: Float, _ l: Float) -> (Float, Float, Float) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let hk = h / 360
        func channel(_ t0: Float) -> Float {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (channel(hk + 1 / 3), channel(hk), channel(hk - 1 / 3))
    }
}

/// Monotone cubic (Fritsch–Carlson) interpolation: smooth, and never overshoots between points.
struct MonotoneCurve {
    private let xs: [Double]
    private let ys: [Double]
    private let ms: [Double]

    init(points: [CurvePoint]) {
        let sorted = points.sorted { $0.x < $1.x }
        var xs: [Double] = []
        var ys: [Double] = []
        for p in sorted where xs.last.map({ p.x - $0 > 1e-6 }) ?? true {
            xs.append(p.x)
            ys.append(p.y)
        }
        if xs.count < 2 { xs = [0, 1]; ys = [0, 1] }
        let n = xs.count
        var deltas = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { deltas[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) }
        var ms = [Double](repeating: 0, count: n)
        ms[0] = deltas[0]
        ms[n - 1] = deltas[n - 2]
        for i in 1..<(n - 1) {
            ms[i] = deltas[i - 1] * deltas[i] <= 0 ? 0 : (deltas[i - 1] + deltas[i]) / 2
        }
        for i in 0..<(n - 1) where deltas[i] != 0 {
            let a = ms[i] / deltas[i], b = ms[i + 1] / deltas[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                ms[i] = t * a * deltas[i]
                ms[i + 1] = t * b * deltas[i]
            }
        }
        self.xs = xs
        self.ys = ys
        self.ms = ms
    }

    func evaluate(_ x: Double) -> Double {
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var i = 0
        while i < xs.count - 2 && x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i]
        let t = (x - xs[i]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * ms[i]
            + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * ms[i + 1]
    }
}
