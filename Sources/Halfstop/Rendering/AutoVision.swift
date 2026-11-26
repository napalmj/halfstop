import Foundation
import CoreImage
import Vision

/// What Vision finds in a photo for the auto actions: faces (for ✦ Auto) and the horizon (for
/// Auto straighten). Every request runs on a small measurement render (512 to 1024 px), never the
/// full-size photo, and only on the auto engine's queue.
///
/// Test hook: `install(faces:for:)` and `install(horizon:for:)` stand in for Vision on a photo, and
/// `visionEnabled = false` turns the real detectors off, so self-tests don't depend on the model's
/// output.
final class AutoVision: @unchecked Sendable {
    static let shared = AutoVision()

    /// A detected horizon, in the app's terms: the Straighten value (degrees) that levels it.
    struct Horizon: Equatable, Sendable {
        /// Degrees for `crop.angle`: positive turns the photo clockwise.
        var angle: Double
        /// 0...1, as Vision reports it.
        var confidence: Double
    }

    /// Faces smaller or less certain than this are ignored (a pattern that only looks like a face).
    static let minFaceConfidence: Float = 0.5

    private let lock = NSLock()
    private var faceOverrides: [URL: [CGRect]] = [:]
    private var horizonOverrides: [URL: Horizon?] = [:]
    private var _visionEnabled = true
    private var warmedUp = false

    /// Off in the self-test: only installed results count.
    var visionEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _visionEnabled }
        set { lock.lock(); _visionEnabled = newValue; lock.unlock() }
    }

    /// Test hook: these faces (normalized, top-left origin, cropped photo) instead of Vision's.
    func install(faces: [CGRect], for url: URL) {
        lock.lock(); faceOverrides[url] = faces; lock.unlock()
    }

    /// Test hook: this horizon (nil = none found) instead of Vision's.
    func install(horizon: Horizon?, for url: URL) {
        lock.lock(); horizonOverrides[url] = .some(horizon); lock.unlock()
    }

    func removeOverrides(for url: URL) {
        lock.lock(); faceOverrides[url] = nil; horizonOverrides[url] = nil; lock.unlock()
    }

    /// Loads the face model once, in the background, the first time the editor opens. The first
    /// face request in a session costs about half a second of model loading; this keeps it out
    /// of the first ✦ Auto click.
    func warmUp() {
        lock.lock()
        let go = !warmedUp && _visionEnabled
        warmedUp = true
        lock.unlock()
        guard go else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: Render.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cg = ctx.makeImage() else { return }
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([VNDetectFaceRectanglesRequest(), VNDetectHorizonRequest()])
        }
    }

    // MARK: Faces

    /// Faces in a measurement render, normalized with a top-left origin (the same frame as the
    /// render: the cropped photo). Sorted largest first.
    func faces(in bm: AutoAdjust.Bitmap, url: URL) -> [CGRect] {
        lock.lock()
        let installed = faceOverrides[url], enabled = _visionEnabled
        lock.unlock()
        if let installed { return installed }
        guard enabled, let cg = bm.cgImage else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
            return []
        }
        let found = (request.results ?? []).filter { $0.confidence >= Self.minFaceConfidence }.map { o in
            // Vision's boxes have a bottom-left origin.
            let b = o.boundingBox
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return found.filter { !$0.isNull && $0.width * $0.height > 0.0004 }.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    // MARK: Horizon

    /// The horizon in an uncropped, unrotated render of the photo, nil if none was found.
    func horizon(in cg: CGImage, url: URL) -> Horizon? {
        lock.lock()
        let installed = horizonOverrides[url], enabled = _visionEnabled
        lock.unlock()
        if let installed { return installed }
        guard enabled else { return nil }
        let request = VNDetectHorizonRequest()
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let o = request.results?.first, o.angle.isFinite else { return nil }
        // Vision reports the rotation that levels the horizon, counterclockwise-positive; the
        // Straighten slider turns the photo the other way round.
        return Horizon(angle: -Double(o.angle) * 180 / .pi, confidence: Double(o.confidence))
    }
}

extension AutoAdjust.Bitmap {
    /// The pixels as a `CGImage` (sRGB, top row first), for Vision.
    var cgImage: CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Render.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// As a Core Image image (for the second opinion), without another render.
    var ciImage: CIImage {
        CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                format: .RGBA8, colorSpace: Render.sRGB)
    }
}
