import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import AppKit

/// Turns a `Mask` description into a grayscale CIImage (white = fully applied)
/// covering an image of `size` with its origin at zero.
enum MaskRenderer {
    static let linearGray = CGColorSpace(name: CGColorSpace.linearGray)!

    /// - Parameters:
    ///   - base: the image the mask is applied to (also what subject detection and the sky look at).
    ///   - canDetect: false for stand-in images (thumbnails), whose geometry may not match the photo.
    static func image(for mask: Mask, size: CGSize, url: URL, base: CIImage, canDetect: Bool = true, exporting: Bool = false) -> CIImage? {
        let extent = CGRect(origin: .zero, size: size)

        // 1. The mask's own content.
        var m: CIImage?
        switch mask.kind {
        case .radial, .linear: m = mask.mainShape.flatMap { shape($0, size: size) }
        case .brush: m = brush(mask.strokes, size: size)
        case .subject:
            m = exporting
                ? SubjectDetector.shared.maskSync(for: url, base: base, size: size, subjects: mask.subjects)
                : SubjectDetector.shared.mask(for: url, base: canDetect ? base : nil, size: size, subjects: mask.subjects)
        case .sky: m = sky(base, size: size)
        }
        m = m?.cropped(to: extent)
        if let mm = m, mask.kind.isAutomatic {
            m = adjustEdges(mm, grow: mask.grow, softness: mask.softness, size: size)
        }

        // 2. Extra shapes, combined in order.
        for extra in mask.shapes {
            guard let s = shape(extra, size: size)?.cropped(to: extent) else { continue }
            let current = m ?? CIImage(color: .black).cropped(to: extent)
            switch extra.mode {
            case .add:
                m = s.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: current])
            case .intersect:
                m = s.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: current])
            case .subtract:
                m = s.applyingFilter("CIColorInvert")
                    .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: current])
            }
            m = m?.cropped(to: extent)
        }

        // 3. Invert, then (for non-brush masks) add/subtract strokes on top of what you see.
        let refines = mask.kind != .brush && !mask.strokes.isEmpty
        guard m != nil || refines || mask.invert else { return nil }
        var out = (m ?? CIImage(color: .black)).cropped(to: extent)
        if mask.invert { out = out.applyingFilter("CIColorInvert").cropped(to: extent) }
        if refines {
            let version = mask.kind == .subject ? SubjectDetector.shared.version(url) : 0
            let cacheable = mask.kind != .sky
            out = refine(out, strokes: mask.strokes, size: size,
                         cacheKey: cacheable ? [mask.shapeKey, version, Int(size.width), Int(size.height)] : nil) ?? out
        }
        return out
    }

    static func shape(_ s: MaskShape, size: CGSize) -> CIImage? {
        switch s.kind {
        case .radial: radial(s, size: size)
        case .linear: linear(s, size: size)
        }
    }

    private static func ci(_ p: NormPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }

    private static func radial(_ mask: MaskShape, size: CGSize) -> CIImage? {
        let f = CIFilter.radialGradient()
        f.center = .zero
        f.radius1 = 100
        f.radius0 = Float(max(0.5, (1 - mask.feather) * 100 - 0.5))
        f.color0 = .white
        f.color1 = .black
        let sx = max(mask.radiusX * size.width, 1) / 100
        let sy = max(mask.radiusY * size.height, 1) / 100
        let c = ci(mask.center, size)
        return f.outputImage?
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: c.x, y: c.y))
    }

    private static func linear(_ mask: MaskShape, size: CGSize) -> CIImage? {
        let f = CIFilter.linearGradient()
        f.point0 = ci(mask.start, size)
        f.point1 = ci(mask.end, size)
        f.color0 = .white
        f.color1 = .black
        return f.outputImage
    }

    /// Bright, blue-ish, upper-frame areas. A heuristic stand-in for a learned sky model.
    private static func sky(_ base: CIImage, size: CGSize) -> CIImage? {
        let extent = CGRect(origin: .zero, size: size)
        let srgb = base.applyingFilter("CILinearToSRGBToneCurve")
        let v = CIVector(x: -0.8 * 1.8, y: 0.6 * 1.8, z: 1.0 * 1.8, w: 0)
        let score = srgb.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -0.45, y: -0.45, z: -0.45, w: 0),
        ]).applyingFilter("CIColorClamp")
        let grad = CIFilter.linearGradient()
        grad.point0 = CGPoint(x: 0, y: size.height)
        grad.point1 = CGPoint(x: 0, y: size.height * 0.2)
        grad.color0 = .white
        grad.color1 = .black
        guard let g = grad.outputImage else { return nil }
        let combined = score.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: g])
        return combined.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(max(size.width, size.height)) * 0.006)
            .cropped(to: extent)
    }

    /// Grow (+) / shrink (-) the edge, then soften it. Both scale with the image so preview and export match.
    static func adjustEdges(_ input: CIImage, grow: Double, softness: Double, size: CGSize) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        let long = Double(max(size.width, size.height))
        var img = input
        if grow != 0 {
            let radius = Float(abs(grow) / 100 * long * 0.02)
            if radius >= 0.5 {
                let name = grow > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum"
                img = img.clampedToExtent().applyingFilter(name, parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
            }
        }
        if softness > 0 {
            img = img.clampedToExtent().applyingGaussianBlur(sigma: softness / 100 * long * 0.012).cropped(to: extent)
        }
        return img
    }

    // MARK: Brush & refinements

    private static let rasterCache: NSCache<NSNumber, CGImage> = {
        let c = NSCache<NSNumber, CGImage>()
        c.countLimit = 24
        return c
    }()

    private static func rasterSize(_ size: CGSize) -> (Int, Int) {
        let longEdge = max(size.width, size.height)
        let res = min(longEdge, longEdge >= 4000 ? 2048 : 1024)
        let scale = res / longEdge
        return (max(Int(size.width * scale), 1), max(Int(size.height * scale), 1))
    }

    private static func brush(_ strokes: [BrushStroke], size: CGSize) -> CIImage? {
        guard !strokes.isEmpty else { return nil }
        let (w, h) = rasterSize(size)
        var hasher = Hasher()
        hasher.combine(strokes); hasher.combine(w); hasher.combine(h)
        let key = NSNumber(value: hasher.finalize())
        let cg: CGImage
        if let hit = rasterCache.object(forKey: key) {
            cg = hit
        } else {
            guard let img = rasterize(strokes, width: w, height: h) else { return nil }
            rasterCache.setObject(img, forKey: key)
            cg = img
        }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(w), y: size.height / CGFloat(h)))
    }

    /// Paints add/subtract strokes on top of an existing mask.
    private static func refine(_ mask: CIImage, strokes: [BrushStroke], size: CGSize, cacheKey: [Int]?) -> CIImage? {
        let (w, h) = rasterSize(size)
        var key: NSNumber?
        if let cacheKey {
            var hasher = Hasher()
            hasher.combine(cacheKey); hasher.combine(w); hasher.combine(h)
            key = NSNumber(value: hasher.finalize())
            if let hit = rasterCache.object(forKey: key!) {
                return CIImage(cgImage: hit).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(w), y: size.height / CGFloat(h)))
            }
        }
        let small = mask.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / size.width, y: CGFloat(h) / size.height))
        guard let baseCG = Render.background.createCGImage(small, from: CGRect(x: 0, y: 0, width: w, height: h),
                                                           format: .L8, colorSpace: linearGray),
              let out = rasterize(strokes, width: w, height: h, background: baseCG) else { return nil }
        if let key { rasterCache.setObject(out, forKey: key) }
        return CIImage(cgImage: out).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(w), y: size.height / CGFloat(h)))
    }

    static func rasterize(_ strokes: [BrushStroke], width: Int, height: Int, background: CGImage? = nil) -> CGImage? {
        let space = background == nil ? CGColorSpaceCreateDeviceGray() : linearGray
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let background { ctx.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        // Flip so normalized top-left coordinates map directly.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let long = CGFloat(max(width, height))
        for stroke in strokes {
            let r = CGFloat(stroke.radius) * long
            let tone: CGFloat = stroke.erase ? 0 : 1
            let core = max(0, 1 - CGFloat(stroke.feather))
            let flow = CGFloat(stroke.flow)
            guard let gradient = CGGradient(colorSpace: space, colorComponents: [tone, flow, tone, flow, tone, 0],
                                            locations: [0, core * 0.999, 1], count: 3) else { continue }
            let pts = stroke.points.map { CGPoint(x: $0.x * Double(width), y: $0.y * Double(height)) }
            var dabs: [CGPoint] = []
            if let first = pts.first { dabs.append(first) }
            let spacing = max(r * 0.2, 0.5)
            for i in 1..<max(pts.count, 1) {
                let a = pts[i - 1], b = pts[i]
                let d = hypot(b.x - a.x, b.y - a.y)
                var t = spacing
                while t <= d {
                    dabs.append(CGPoint(x: a.x + (b.x - a.x) * t / d, y: a.y + (b.y - a.y) * t / d))
                    t += spacing
                }
                if d < spacing { dabs.append(b) }
            }
            for p in dabs {
                ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
            }
        }
        return ctx.makeImage()
    }
}

/// Finds subjects with Vision — on the same image the editor shows, so the mask lines up —
/// and keeps one mask per subject so they can be picked individually.
final class SubjectDetector: @unchecked Sendable {
    static let shared = SubjectDetector()

    struct Detection {
        /// All subjects together (soft edges), linear gray.
        let all: CGImage
        /// One mask per subject, same size as `all`.
        let instances: [CGImage]
        /// Downsampled per-subject coverage for click lookups.
        let lookup: [[UInt8]]
        let lookupSize: (Int, Int)
    }

    private let lock = NSLock()
    private var detections: [URL: Detection] = [:]
    private var failed: Set<URL> = []
    private var inflight: Set<URL> = []
    private var versions: [URL: Int] = [:]
    private var subsetCache: [String: CGImage] = [:]
    /// Called on the main thread when a detection finishes.
    var onDetected: ((URL) -> Void)?

    func version(_ url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return versions[url] ?? 0
    }

    /// nil while detecting (or never started); 0 when nothing was found.
    func subjectCount(_ url: URL) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if failed.contains(url) { return 0 }
        return detections[url]?.instances.count
    }

    func isDetecting(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inflight.contains(url)
    }

    /// Which subject (1-based) covers a normalized point, if any.
    func subject(at p: NormPoint, url: URL) -> Int? {
        lock.lock(); let d = detections[url]; lock.unlock()
        guard let d else { return nil }
        let (w, h) = d.lookupSize
        let x = min(max(Int(p.x * Double(w)), 0), w - 1), y = min(max(Int(p.y * Double(h)), 0), h - 1)
        var best: (Int, UInt8)?
        for (i, plane) in d.lookup.enumerated() {
            let v = plane[y * w + x]
            if v > 100, v > (best?.1 ?? 0) { best = (i + 1, v) }
        }
        return best?.0
    }

    /// The subject mask scaled to `size`. Starts detection on `base` if needed (pass nil to never start it).
    func mask(for url: URL, base: CIImage?, size: CGSize, subjects: [Int]?) -> CIImage? {
        lock.lock()
        let hit = detections[url]
        let shouldStart = hit == nil && base != nil && !failed.contains(url) && !inflight.contains(url)
        if shouldStart { inflight.insert(url) }
        lock.unlock()
        if shouldStart, let base {
            DispatchQueue.global(qos: .userInitiated).async { self.detect(url, base: base) }
        }
        guard let hit else { return nil }
        return compose(hit, url: url, subjects: subjects, size: size)
    }

    /// Blocking variant for export.
    func maskSync(for url: URL, base: CIImage, size: CGSize, subjects: [Int]?) -> CIImage? {
        lock.lock()
        let hit = detections[url]
        let busy = inflight.contains(url)
        lock.unlock()
        if let hit { return compose(hit, url: url, subjects: subjects, size: size) }
        if busy {
            while isDetecting(url) { Thread.sleep(forTimeInterval: 0.05) }
        } else {
            lock.lock(); inflight.insert(url); lock.unlock()
            detect(url, base: base)
        }
        return mask(for: url, base: nil, size: size, subjects: subjects)
    }

    private func compose(_ d: Detection, url: URL, subjects: [Int]?, size: CGSize) -> CIImage {
        let cg: CGImage
        let wanted = subjects.map { Set($0.filter { $0 >= 1 && $0 <= d.instances.count }) }
        if let wanted, wanted.count < d.instances.count {
            let key = "\(url.path)#\(wanted.sorted())#\(version(url))"
            lock.lock(); let cached = subsetCache[key]; lock.unlock()
            if let cached {
                cg = cached
            } else {
                var img = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: d.all.width, height: d.all.height))
                for i in wanted.sorted() {
                    img = CIImage(cgImage: d.instances[i - 1]).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: img])
                }
                let made = Render.background.createCGImage(img, from: img.extent, format: .L8, colorSpace: MaskRenderer.linearGray) ?? d.all
                lock.lock(); subsetCache[key] = made; lock.unlock()
                cg = made
            }
        } else {
            cg = d.all
        }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(cg.width), y: size.height / CGFloat(cg.height)))
    }

    private func detect(_ url: URL, base: CIImage) {
        let result = SubjectDetector.run(base)
        lock.lock()
        inflight.remove(url)
        if let result { detections[url] = result; failed.remove(url) } else { failed.insert(url) }
        versions[url, default: 0] += 1
        subsetCache = subsetCache.filter { !$0.key.hasPrefix(url.path + "#") }
        lock.unlock()
        DispatchQueue.main.async { self.onDetected?(url) }
    }

    /// Test hook: install a detection without running Vision.
    func install(_ d: Detection, for url: URL) {
        lock.lock()
        detections[url] = d
        versions[url, default: 0] += 1
        lock.unlock()
    }

    private static func run(_ base: CIImage) -> Detection? {
        let e = base.extent
        guard e.width > 0, e.height > 0, e.width.isFinite else { return nil }
        let s = min(1, 1536 / max(e.width, e.height))
        let scaled = base.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).scaledBy(x: s, y: s))
        let rect = CGRect(x: 0, y: 0, width: (e.width * s).rounded(.down), height: (e.height * s).rounded(.down))
        guard let cg = Render.background.createCGImage(scaled, from: rect, format: .RGBA8, colorSpace: Render.sRGB) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
            guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return nil }
            func bake(_ set: IndexSet) throws -> CGImage? {
                let buffer = try obs.generateScaledMaskForImage(forInstances: set, from: handler)
                let img = CIImage(cvPixelBuffer: buffer)
                return Render.background.createCGImage(img, from: img.extent, format: .L8, colorSpace: MaskRenderer.linearGray)
            }
            guard let all = try bake(obs.allInstances) else { return nil }
            var instances: [CGImage] = []
            for i in obs.allInstances.sorted() {
                if let m = try bake(IndexSet(integer: i)) { instances.append(m) }
            }
            let (lw, lh) = (256, max(1, Int(256 * Double(all.height) / Double(all.width))))
            let lookup = instances.map { downsample($0, width: lw, height: lh) }
            return Detection(all: all, instances: instances, lookup: lookup, lookupSize: (lw, lh))
        } catch {
            return nil
        }
    }

    static func downsample(_ img: CGImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: MaskRenderer.linearGray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}
