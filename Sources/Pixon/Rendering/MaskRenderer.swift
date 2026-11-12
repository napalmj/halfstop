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
        case .brush: m = brush(mask.strokes, size: size, maskID: mask.id)
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
            var unrefined = mask
            unrefined.strokes = []
            out = refine(out, strokes: mask.strokes, size: size, maskID: mask.id,
                         baseKey: cacheable ? [unrefined.shapeKey, version, Int(size.width), Int(size.height)] : nil,
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

    private static func scaled(_ cg: CGImage, to size: CGSize) -> CIImage {
        CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(cg.width), y: size.height / CGFloat(cg.height)))
    }

    private static func brush(_ strokes: [BrushStroke], size: CGSize, maskID: UUID) -> CIImage? {
        guard !strokes.isEmpty else { return nil }
        let (w, h) = rasterSize(size)
        // A stroke in progress only paints its new dabs onto what's already there.
        if let cg = LiveRaster.extend(maskID: maskID, width: w, height: h, baseKey: nil, strokes: strokes) {
            return scaled(cg, to: size)
        }
        var hasher = Hasher()
        hasher.combine(strokes); hasher.combine(w); hasher.combine(h)
        let key = NSNumber(value: hasher.finalize())
        if let hit = rasterCache.object(forKey: key) { return scaled(hit, to: size) }
        guard let cg = LiveRaster.rebuild(maskID: maskID, width: w, height: h, background: nil, baseKey: nil, strokes: strokes) else { return nil }
        rasterCache.setObject(cg, forKey: key)
        return scaled(cg, to: size)
    }

    /// Paints add/subtract strokes on top of an existing mask.
    /// - baseKey: identifies the unrefined mask; nil when it can't be cached (sky), which forces a readback.
    private static func refine(_ mask: CIImage, strokes: [BrushStroke], size: CGSize, maskID: UUID,
                               baseKey: [Int]?, cacheKey: [Int]?) -> CIImage? {
        let (w, h) = rasterSize(size)
        var bk: Int?
        if let baseKey {
            var hasher = Hasher()
            hasher.combine(baseKey); hasher.combine(w); hasher.combine(h)
            bk = hasher.finalize()
            if let cg = LiveRaster.extend(maskID: maskID, width: w, height: h, baseKey: bk, strokes: strokes) {
                return scaled(cg, to: size)
            }
        }
        var key: NSNumber?
        if let cacheKey {
            var hasher = Hasher()
            hasher.combine(cacheKey); hasher.combine(w); hasher.combine(h)
            key = NSNumber(value: hasher.finalize())
            if let hit = rasterCache.object(forKey: key!) { return scaled(hit, to: size) }
        }
        let small = mask.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / size.width, y: CGFloat(h) / size.height))
        guard let baseCG = Render.background.createCGImage(small, from: CGRect(x: 0, y: 0, width: w, height: h),
                                                           format: .L8, colorSpace: linearGray),
              let out = LiveRaster.rebuild(maskID: maskID, width: w, height: h, background: baseCG, baseKey: bk, strokes: strokes)
        else { return nil }
        if let key { rasterCache.setObject(out, forKey: key) }
        return scaled(out, to: size)
    }

    static func rasterize(_ strokes: [BrushStroke], width: Int, height: Int, background: CGImage? = nil) -> CGImage? {
        guard let ctx = StrokePainter.context(width: width, height: height, background: background) else { return nil }
        for stroke in strokes { StrokePainter.paint(stroke, from: 0, in: ctx, width: width, height: height) }
        return ctx.makeImage()
    }
}

/// Draws brush strokes as feathered dabs into an 8-bit gray bitmap.
enum StrokePainter {
    /// A black bitmap (optionally starting from `background`), flipped so normalized
    /// top-left stroke coordinates map directly.
    static func context(width: Int, height: Int, background: CGImage?) -> CGContext? {
        let space = background == nil ? CGColorSpaceCreateDeviceGray() : MaskRenderer.linearGray
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let background { ctx.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    /// Paints a stroke's dabs starting at segment `from` (segment i joins points i-1 and i;
    /// 0 also paints the first point). Painting 0..<k and then k... gives the same pixels as
    /// painting the whole stroke at once, which is what lets live strokes grow incrementally.
    static func paint(_ stroke: BrushStroke, from: Int, in ctx: CGContext, width: Int, height: Int) {
        guard let space = ctx.colorSpace, !stroke.points.isEmpty, from < stroke.points.count else { return }
        let long = CGFloat(max(width, height))
        let r = CGFloat(stroke.radius) * long
        let tone: CGFloat = stroke.erase ? 0 : 1
        let core = max(0, 1 - CGFloat(stroke.feather))
        let flow = CGFloat(stroke.flow)
        guard let gradient = CGGradient(colorSpace: space, colorComponents: [tone, flow, tone, flow, tone, 0],
                                        locations: [0, core * 0.999, 1], count: 3) else { return }
        func pt(_ i: Int) -> CGPoint { CGPoint(x: stroke.points[i].x * Double(width), y: stroke.points[i].y * Double(height)) }
        func dab(_ p: CGPoint) {
            ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
        }
        if from == 0 { dab(pt(0)) }
        let spacing = max(r * 0.2, 0.5)
        for i in max(from, 1)..<max(stroke.points.count, 1) {
            let a = pt(i - 1), b = pt(i)
            let d = hypot(b.x - a.x, b.y - a.y)
            var t = spacing
            while t <= d {
                dab(CGPoint(x: a.x + (b.x - a.x) * t / d, y: a.y + (b.y - a.y) * t / d))
                t += spacing
            }
            if d < spacing { dab(b) }
        }
    }
}

/// Per-mask bitmaps kept between frames. While you paint, each frame adds one point to the
/// last stroke; instead of re-painting every stroke (cost growing with everything painted so
/// far), only the new segment's dabs are drawn onto the bitmap from the previous frame.
enum LiveRaster {
    private final class Entry {
        let ctx: CGContext
        let baseKey: Int?
        var drawn: [BrushStroke]
        var image: CGImage?
        init(ctx: CGContext, baseKey: Int?, drawn: [BrushStroke]) {
            self.ctx = ctx; self.baseKey = baseKey; self.drawn = drawn
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    private static let maxEntries = 8

    private static func key(_ id: UUID, _ w: Int, _ h: Int) -> String { "\(id.uuidString)#\(w)x\(h)" }

    /// The bitmap for `strokes` if it can be had from the last one painted for this mask and size
    /// (unchanged, or the same strokes plus new points/strokes at the end); nil means rebuild.
    static func extend(maskID: UUID, width: Int, height: Int, baseKey: Int?, strokes: [BrushStroke]) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[key(maskID, width, height)], e.baseKey == baseKey,
              let start = appendedFrom(e.drawn, to: strokes) else { return nil }
        if start.stroke == strokes.count { return e.image }  // nothing new
        for i in start.stroke..<strokes.count {
            StrokePainter.paint(strokes[i], from: i == start.stroke ? start.segment : 0, in: e.ctx, width: width, height: height)
        }
        e.drawn = strokes
        e.image = e.ctx.makeImage()
        return e.image
    }

    /// Paints all strokes from scratch and keeps the bitmap for later `extend` calls.
    static func rebuild(maskID: UUID, width: Int, height: Int, background: CGImage?, baseKey: Int?, strokes: [BrushStroke]) -> CGImage? {
        guard let ctx = StrokePainter.context(width: width, height: height, background: background) else { return nil }
        for stroke in strokes { StrokePainter.paint(stroke, from: 0, in: ctx, width: width, height: height) }
        let entry = Entry(ctx: ctx, baseKey: baseKey, drawn: strokes)
        entry.image = ctx.makeImage()
        lock.lock(); defer { lock.unlock() }
        let k = key(maskID, width, height)
        if entries[k] == nil, entries.count >= maxEntries, let victim = entries.keys.first { entries[victim] = nil }
        entries[k] = entry
        return entry.image
    }

    /// Where `new` continues `old`: the first stroke index with unpainted content and, for that
    /// stroke, the first unpainted segment. nil if `new` isn't `old` with things appended.
    static func appendedFrom(_ old: [BrushStroke], to new: [BrushStroke]) -> (stroke: Int, segment: Int)? {
        guard new.count >= old.count else { return nil }
        guard let lastOld = old.last else { return (0, 0) }
        let n = old.count - 1
        for i in 0..<n where new[i] != old[i] { return nil }
        let a = lastOld, b = new[n]
        guard a.radius == b.radius, a.feather == b.feather, a.flow == b.flow, a.erase == b.erase,
              b.points.count >= a.points.count, Array(b.points.prefix(a.points.count)) == a.points else { return nil }
        if b.points.count == a.points.count { return (n + 1, 0) }
        return (n, a.points.count)
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
