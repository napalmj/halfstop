import Foundation
import CoreImage

/// A one-click auto action.
enum AutoKind: Hashable, Sendable {
    /// White balance, tone, whites/blacks and vibrance together (the ✦ Auto chip).
    case auto
    case tone
    case whiteBalance
    /// White balance from a clicked spot (normalized, top-left origin, in the cropped photo).
    case pickedWhite(NormRect)

    /// The history step it makes.
    var label: String {
        switch self {
        case .auto: "Auto"
        case .tone: "Auto tone"
        case .whiteBalance: "Auto white balance"
        case .pickedWhite: "White balance (picked)"
        }
    }
}

/// What an auto action decided, plus what it measured. `nil` parts aren't touched when applied.
///
/// Extending it: add the new decision as another optional part (a learned per-user offset, say)
/// and set it in `applied(to:)`; add what it was based on next to `stats` and `hints`.
struct AutoResult: Equatable, Sendable {
    var whiteBalance: AutoAdjust.WhiteBalance?
    var tone: AutoAdjust.Tone?
    var levels: AutoAdjust.Levels?
    var color: AutoAdjust.ColorBoost?
    /// How the photo was read (decides how hard tone pushes).
    var scene: AutoAdjust.Scene?
    /// The measurement the tone and color decisions were based on (after white balance).
    var stats: ImageStats?
    /// What else was known about the photo (faces…).
    var hints = AutoHints()

    /// `a` with this result's sliders set; everything else (curve, masks, crop…) stays.
    func applied(to a: Adjustments) -> Adjustments {
        var out = a
        if let wb = whiteBalance { out.temperature = wb.temperature; out.tint = wb.tint }
        if let t = tone {
            out.exposure = t.exposure; out.contrast = t.contrast; out.highlights = t.highlights; out.shadows = t.shadows
        }
        if let l = levels { out.whites = l.whites; out.blacks = l.blacks }
        if let c = color { out.vibrance = c.vibrance; out.saturation = c.saturation }
        return out
    }
}

/// One auto action on one photo. Equal requests always give equal results, so it doubles as the cache key.
struct AutoRequest: Hashable, Sendable {
    let url: URL
    let kind: AutoKind
    /// Only the parts of the current edits this kind of measurement reads (all else default),
    /// so unrelated edits (a mask, the vignette) don't miss the cache.
    let inputs: Adjustments

    init(url: URL, kind: AutoKind, adjustments a: Adjustments) {
        self.url = url
        self.kind = kind
        var inputs = Adjustments()
        inputs.crop = a.crop
        switch kind {
        case .auto:
            break   // starts from defaults: only the crop matters
        case .tone:
            inputs.temperature = a.temperature
            inputs.tint = a.tint
        case .whiteBalance, .pickedWhite:
            inputs.exposure = a.exposure
        }
        self.inputs = inputs
    }
}

/// Runs auto measurements off the main thread, on a small decode of the photo it owns (the
/// preview's `ImageSource` isn't thread-safe), and remembers results so repeating an action,
/// or undo then redo, is instant.
final class AutoEngine: @unchecked Sendable {
    static let shared = AutoEngine()

    /// Long edge of the measurement decode. Measurements render at `AutoAdjust.measureSize`;
    /// the extra resolution is there for detectors that want up to 1024 px.
    static let decodeSize: CGFloat = 1024

    private let queue = DispatchQueue(label: "halfstop.auto", qos: .userInitiated)

    /// A file as it was when measured: an edit on disk changes the stamp and so misses the cache.
    private struct FileStamp: Hashable {
        let url: URL
        let modified: Date?
        let size: Int?
    }
    private struct Key: Hashable {
        let request: AutoRequest
        let stamp: FileStamp
    }

    // Touched only on `queue`.
    private var sources: [(stamp: FileStamp, source: ImageSource)] = []
    private var results: [Key: AutoResult] = [:]
    private var resultOrder: [Key] = []
    private var measurements = 0
    private static let sourceLimit = 2
    private static let resultLimit = 64

    /// The result for `request`, computed on the engine's queue (or from the cache).
    /// nil if the photo can't be read.
    func result(for request: AutoRequest) async -> AutoResult? {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.compute(request)) }
        }
    }

    /// Blocking version for the benchmark and the self-test. Never call it on the main thread in the app.
    func resultNow(for request: AutoRequest) -> AutoResult? {
        queue.sync { compute(request) }
    }

    /// Forgets results (and with `sources`, the decodes too), for benchmarking cold and warm paths.
    func clear(sources clearSources: Bool = false) {
        queue.sync {
            results = [:]; resultOrder = []
            if clearSources { sources = [] }
        }
    }

    /// How many requests were measured rather than answered from the cache (for the self-test).
    var measurementCount: Int { queue.sync { measurements } }

    private func compute(_ request: AutoRequest) -> AutoResult? {
        dispatchPrecondition(condition: .onQueue(queue))
        let stamp = Self.stamp(request.url)
        let key = Key(request: request, stamp: stamp)
        if let hit = results[key] {
            resultOrder.removeAll { $0 == key }
            resultOrder.append(key)
            return hit
        }
        guard let source = source(for: stamp) else { return nil }
        measurements += 1
        let result = AutoAdjust.compute(request.kind, source: source, inputs: request.inputs)
        results[key] = result
        resultOrder.append(key)
        if resultOrder.count > Self.resultLimit { results[resultOrder.removeFirst()] = nil }
        return result
    }

    private func source(for stamp: FileStamp) -> ImageSource? {
        if let i = sources.firstIndex(where: { $0.stamp == stamp }) {
            let hit = sources.remove(at: i)
            sources.append(hit)
            return hit.source
        }
        guard let s = ImageSource(url: stamp.url, maxPixelSize: Self.decodeSize) else { return nil }
        sources.removeAll { $0.stamp.url == stamp.url }
        sources.append((stamp, s))
        if sources.count > Self.sourceLimit { sources.removeFirst() }
        return s
    }

    private static func stamp(_ url: URL) -> FileStamp {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return FileStamp(url: url, modified: attrs?[.modificationDate] as? Date, size: (attrs?[.size] as? NSNumber)?.intValue)
    }
}

extension AutoAdjust {
    /// Measures and decides one auto action. `inputs` holds only what `AutoRequest` keeps.
    static func compute(_ kind: AutoKind, source: ImageSource, inputs: Adjustments) -> AutoResult {
        switch kind {
        case .auto:
            return auto(source: source, inputs: inputs)
        case .whiteBalance:
            return AutoResult(whiteBalance: whiteBalance(source: source, adjustments: inputs, region: nil))
        case .pickedWhite(let r):
            let region = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            return AutoResult(whiteBalance: whiteBalance(source: source, adjustments: inputs, region: region))
        case .tone:
            guard let stats = measure(measurementImage(source, inputs)) else {
                return AutoResult(tone: Tone(exposure: 0, contrast: 0, highlights: 0, shadows: 0))
            }
            let scene = scene(stats)
            return AutoResult(tone: tone(stats, scene: scene), scene: scene, stats: stats)
        }
    }
}
