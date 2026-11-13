import Foundation

/// "Learn from my edits": ✦ Auto adapts to how this user finishes photos, on the device, from their
/// own edits only. No dataset, no training: for each photo edited by hand, the catalog keeps a few
/// numbers describing the photo (`StyleFeatures`) and what ✦ Auto gave it; the difference between
/// the user's final sliders and that is what they wanted. ✦ Auto then adds the distance-weighted
/// average difference of the most similar edited photos (`StyleModel`).

/// The ten global sliders ✦ Auto sets, in a fixed order.
enum StyleSliders {
    static let names = ["temperature", "tint", "exposure", "contrast", "highlights", "shadows", "whites", "blacks", "vibrance", "saturation"]
    static var count: Int { names.count }

    static func values(_ a: Adjustments) -> [Double] {
        [a.temperature, a.tint, a.exposure, a.contrast, a.highlights, a.shadows, a.whites, a.blacks, a.vibrance, a.saturation]
    }

    /// The largest learned change per slider: a style nudges, it doesn't take over.
    static let maxOffset: [Double] = [25, 20, 1.0, 30, 40, 40, 30, 30, 30, 20]
    /// Slider step (exposure in 0.05 EV, the rest whole numbers).
    static let step: [Double] = [1, 1, 0.05, 1, 1, 1, 1, 1, 1, 1]

    /// Edited by hand, as far as learning is concerned: at least one of the sliders was moved.
    /// (A photo that was only cropped or masked says nothing about tone and color.)
    static func isEdited(_ a: Adjustments) -> Bool { values(a).contains { $0 != 0 } }
}

/// A learned change to ✦ Auto's sliders, in `StyleSliders` order.
struct StyleOffset: Equatable, Sendable {
    var values: [Double]

    var isZero: Bool { values.allSatisfy { $0 == 0 } }

    /// `a` with the offset added, each slider kept in its range.
    func applied(to a: Adjustments) -> Adjustments {
        guard values.count == StyleSliders.count else { return a }
        var out = a
        let v = values
        func add(_ x: Double, _ d: Double, _ r: ClosedRange<Double> = -100...100) -> Double { (x + d).clamped(to: r) }
        out.temperature = add(a.temperature, v[0]); out.tint = add(a.tint, v[1])
        out.exposure = ((add(a.exposure, v[2], -5...5)) * 20).rounded() / 20 + 0
        out.contrast = add(a.contrast, v[3]); out.highlights = add(a.highlights, v[4]); out.shadows = add(a.shadows, v[5])
        out.whites = add(a.whites, v[6]); out.blacks = add(a.blacks, v[7])
        out.vibrance = add(a.vibrance, v[8]); out.saturation = add(a.saturation, v[9])
        return out
    }
}

/// What a photo looks like, as a dozen numbers of similar scale, from ✦ Auto's measurement.
enum StyleFeatures {
    /// Bump when the features or ✦ Auto's decisions change: older samples are measured again.
    static let version = 1
    static let count = 12

    /// - 0…4: luminance percentiles 5/25/50/75/95 after auto white balance (sRGB-encoded)
    /// - 5, 6: the as-shot color cast, log(R/G) and log(B/G) of the mean (halved, ±1)
    /// - 7: as-shot mean brightness (sRGB-encoded)
    /// - 8: mean perceptual chroma after white balance (×5)
    /// - 9, 10: faces present (0 or 0.5), and how much of the frame they cover (square root)
    /// - 11: RAW (0 or 0.5)
    static func make(_ r: AutoResult, isRAW: Bool) -> [Double]? {
        guard let s = r.stats, s.pixelCount > 16 else { return nil }
        var f = [0.05, 0.25, 0.5, 0.75, 0.95].map { s.percentile($0) }
        let m = r.asShotMean ?? s.meanRGB
        let g = max(m.y, 1e-4)
        f.append((log(max(m.x, 1e-4) / g) * 0.5).clamped(to: -1...1))
        f.append((log(max(m.z, 1e-4) / g) * 0.5).clamped(to: -1...1))
        f.append(AutoAdjust.encoded(min(max(0.2126 * m.x + 0.7152 * m.y + 0.0722 * m.z, 0), 1)))
        f.append(min(s.meanChroma * 5, 1))
        let area = r.hints.faces.reduce(0.0) { $0 + Double($1.width * $1.height) }
        f.append(r.hints.faces.isEmpty ? 0 : 0.5)
        f.append(min(area, 1).squareRoot())
        f.append(isRAW ? 0.5 : 0)
        return f.allSatisfy(\.isFinite) ? f : nil
    }
}

/// One edited photo's learning record, kept in the catalog (`Catalog.styleSamples`).
struct StyleSample: Codable, Hashable {
    /// `StyleFeatures.version` it was measured with.
    var version: Int
    var features: [Double]
    /// What ✦ Auto gave the photo (`StyleSliders` order).
    var auto: [Double]
    /// The crop it was measured with (the features describe the cropped photo).
    var crop: CropSettings
    var date: Date

    init(version: Int = StyleFeatures.version, features: [Double], auto: [Double], crop: CropSettings, date: Date = Date()) {
        self.version = version; self.features = features; self.auto = auto; self.crop = crop; self.date = date
    }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        version = t.value(.version, 0)
        features = try t.required(.features)
        auto = try t.required(.auto)
        crop = t.value(.crop, CropSettings())
        date = t.value(.date, Date())
    }

    /// Current and well-formed: usable for a photo with this crop.
    func isUsable(crop c: CropSettings) -> Bool {
        version == StyleFeatures.version && features.count == StyleFeatures.count && auto.count == StyleSliders.count
            && crop == c && features.allSatisfy(\.isFinite) && auto.allSatisfy(\.isFinite)
    }
}

/// The in-memory index of edited photos: features and what the user changed on top of ✦ Auto.
/// Updated one photo at a time as edits happen; a brute-force nearest-neighbour search over a
/// few thousand 12-number vectors takes well under a millisecond.
struct StyleModel {
    /// Neighbours averaged per prediction.
    static let k = 8
    /// Below this many edited photos ✦ Auto stays plain.
    static let minimumSamples = 20

    struct Entry {
        var features: [Double]
        var delta: [Double]
    }

    private(set) var entries: [String: Entry] = [:]

    var count: Int { entries.count }
    var isActive: Bool { entries.count >= Self.minimumSamples }

    /// Records (or replaces) a photo: its sample and its current sliders. Removed when it isn't
    /// edited by hand or the sample doesn't fit.
    mutating func update(_ key: String, sample: StyleSample?, adjustments: Adjustments) {
        guard let sample, sample.isUsable(crop: adjustments.crop), StyleSliders.isEdited(adjustments) else {
            entries[key] = nil
            return
        }
        let mine = StyleSliders.values(adjustments)
        entries[key] = Entry(features: sample.features, delta: zip(mine, sample.auto).map { $0 - $1 })
    }

    mutating func remove(_ key: String) { entries[key] = nil }
    mutating func removeAll() { entries = [:] }

    /// Directly sets an entry (tests).
    mutating func set(_ key: String, features: [Double], delta: [Double]) {
        entries[key] = Entry(features: features, delta: delta)
    }

    /// The learned change for a photo with `features`: the distance-weighted mean difference of
    /// its `k` nearest edited photos (never itself), clamped to `StyleSliders.maxOffset` and
    /// rounded to slider steps. nil with too few edited photos, or when it rounds to nothing.
    func predict(_ features: [Double], excluding key: String? = nil) -> StyleOffset? {
        guard features.count == StyleFeatures.count else { return nil }
        var near: [(d: Double, delta: [Double])] = []
        near.reserveCapacity(entries.count)
        for (k, e) in entries where k != key && e.features.count == features.count && e.delta.count == StyleSliders.count {
            var d = 0.0
            for i in 0..<features.count { let x = e.features[i] - features[i]; d += x * x }
            near.append((d.squareRoot(), e.delta))
        }
        guard near.count >= Self.minimumSamples else { return nil }
        near.sort { $0.d < $1.d }
        var sum = [Double](repeating: 0, count: StyleSliders.count), total = 0.0
        for n in near.prefix(Self.k) {
            let w = 1 / (n.d + 0.05)
            for i in 0..<sum.count { sum[i] += n.delta[i] * w }
            total += w
        }
        guard total > 0 else { return nil }
        let out = (0..<sum.count).map { i -> Double in
            let m = StyleSliders.maxOffset[i], step = StyleSliders.step[i]
            return ((sum[i] / total).clamped(to: -m...m) / step).rounded() * step + 0
        }
        let offset = StyleOffset(values: out)
        return offset.isZero ? nil : offset
    }
}
