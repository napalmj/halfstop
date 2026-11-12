import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import AppKit

/// Turns a `Mask` description into a grayscale CIImage (white = fully applied)
/// covering an image of `size` with its origin at zero.
enum MaskRenderer {
    static func image(for mask: Mask, size: CGSize, url: URL, base: CIImage) -> CIImage? {
        let extent = CGRect(origin: .zero, size: size)
        var m: CIImage?
        switch mask.kind {
        case .radial: m = radial(mask, size: size)
        case .linear: m = linear(mask, size: size)
        case .brush: m = brush(mask.strokes, size: size)
        case .subject: m = SubjectDetector.shared.mask(for: url, size: size)
        case .sky: m = sky(base, size: size)
        }
        guard var out = m?.cropped(to: extent) else {
            // Nothing to apply yet (e.g. subject still being detected); inverted means "everything".
            return mask.invert ? CIImage(color: .white).cropped(to: extent) : nil
        }
        if mask.invert { out = out.applyingFilter("CIColorInvert").cropped(to: extent) }
        return out
    }

    private static func ci(_ p: NormPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }

    private static func radial(_ mask: Mask, size: CGSize) -> CIImage? {
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

    private static func linear(_ mask: Mask, size: CGSize) -> CIImage? {
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

    // MARK: Brush

    private static let brushCache: NSCache<NSNumber, CGImage> = {
        let c = NSCache<NSNumber, CGImage>()
        c.countLimit = 16
        return c
    }()

    private static func brush(_ strokes: [BrushStroke], size: CGSize) -> CIImage? {
        guard !strokes.isEmpty else { return nil }
        let longEdge = max(size.width, size.height)
        let res = min(longEdge, longEdge >= 4000 ? 2048 : 1024)
        let scale = res / longEdge
        let w = max(Int(size.width * scale), 1), h = max(Int(size.height * scale), 1)
        var hasher = Hasher()
        hasher.combine(strokes)
        hasher.combine(w)
        hasher.combine(h)
        let key = NSNumber(value: hasher.finalize())
        let cg: CGImage
        if let hit = brushCache.object(forKey: key) {
            cg = hit
        } else {
            guard let img = rasterize(strokes, width: w, height: h) else { return nil }
            brushCache.setObject(img, forKey: key)
            cg = img
        }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(w), y: size.height / CGFloat(h)))
    }

    static func rasterize(_ strokes: [BrushStroke], width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip so normalized top-left coordinates map directly.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let long = CGFloat(max(width, height))
        let space = CGColorSpaceCreateDeviceGray()
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

/// Finds the main subject(s) with Vision and caches the mask per photo.
final class SubjectDetector: @unchecked Sendable {
    static let shared = SubjectDetector()

    private let lock = NSLock()
    private var masks: [URL: CIImage] = [:]
    private var failed: Set<URL> = []
    private var inflight: Set<URL> = []
    /// Called on the main thread when a detection finishes.
    var onDetected: ((URL) -> Void)?

    /// The cached subject mask scaled to `size`; kicks off detection if missing.
    func mask(for url: URL, size: CGSize) -> CIImage? {
        lock.lock()
        let hit = masks[url]
        let shouldStart = hit == nil && !failed.contains(url) && !inflight.contains(url)
        if shouldStart { inflight.insert(url) }
        lock.unlock()
        if shouldStart {
            DispatchQueue.global(qos: .userInitiated).async { self.detect(url) }
        }
        guard let hit else { return nil }
        return hit.transformed(by: CGAffineTransform(scaleX: size.width / hit.extent.width, y: size.height / hit.extent.height))
    }

    /// Blocking variant for export.
    func maskSync(for url: URL, size: CGSize) -> CIImage? {
        if let m = mask(for: url, size: size) { return m }
        detect(url)
        return mask(for: url, size: size)
    }

    private func detect(_ url: URL) {
        let result = SubjectDetector.run(url)
        lock.lock()
        inflight.remove(url)
        if let result { masks[url] = result } else { failed.insert(url) }
        lock.unlock()
        DispatchQueue.main.async { self.onDetected?(url) }
    }

    private static func run(_ url: URL) -> CIImage? {
        guard let cg = ImageSource.downsampled(url: url, maxPixelSize: 1536, preferEmbedded: true) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
            guard let obs = request.results?.first else { return nil }
            let buffer = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
            let img = CIImage(cvPixelBuffer: buffer)
            // Bake into a CGImage so the pixel buffer can be released.
            guard let baked = Render.background.createCGImage(img, from: img.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
            return CIImage(cgImage: baked)
        } catch {
            return nil
        }
    }
}
