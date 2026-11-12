import Foundation

/// A photo's files in `<folder>/.pixon/`:
/// - `<name>.json`: rating, flag, current adjustments and snapshots. Small; written about
///   0.5 s after any change.
/// - `<name>.history.json`: the edit history, written only when the history itself changes.
///   Every step holds the full adjustments, so brush strokes would repeat in each step;
///   instead each distinct stroke is stored once and steps refer to it by key.
///
/// Older sidecars kept the history inline in `<name>.json`; they still load, and move to
/// the separate file on their next save.
enum SidecarFiles {
    static func mainURL(for photo: URL) -> URL {
        photo.deletingLastPathComponent()
            .appendingPathComponent(".pixon", isDirectory: true)
            .appendingPathComponent(photo.lastPathComponent + ".json")
    }

    static func historyURL(for photo: URL) -> URL {
        photo.deletingLastPathComponent()
            .appendingPathComponent(".pixon", isDirectory: true)
            .appendingPathComponent(photo.lastPathComponent + ".history.json")
    }

    /// Every sidecar file a photo can have (for renames and trashing).
    static func all(for photo: URL) -> [URL] { [mainURL(for: photo), historyURL(for: photo)] }

    static func read(for photo: URL) -> Sidecar? {
        let decoder = JSONDecoder()
        guard var sidecar = (try? Data(contentsOf: mainURL(for: photo))).flatMap({ try? decoder.decode(Sidecar.self, from: $0) }) else {
            return nil
        }
        if let data = try? Data(contentsOf: historyURL(for: photo)),
           let file = try? decoder.decode(HistoryFile.self, from: data) {
            sidecar.history = file.historySteps()
            sidecar.historyIndex = file.index
        }
        return sidecar
    }

    /// - Parameter history: also write the history file. Ignored (written anyway) when the history
    ///   only exists inline in an older sidecar, so it isn't lost when the main file is rewritten.
    static func write(_ sidecar: Sidecar, for photo: URL, history: Bool) {
        let main = mainURL(for: photo), hist = historyURL(for: photo)
        let fm = FileManager.default
        if sidecar.isEmpty {
            try? fm.removeItem(at: main)
            try? fm.removeItem(at: hist)
            return
        }
        try? fm.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let writeHistory = history || (!fm.fileExists(atPath: hist.path) && sidecar.history.count > 1)
        if writeHistory, let data = try? encoder.encode(HistoryFile(sidecar.history, index: sidecar.historyIndex)) {
            try? data.write(to: hist, options: .atomic)
        }
        if let data = try? encoder.encode(MainFile(sidecar)) { try? data.write(to: main, options: .atomic) }
    }
}

/// What `<name>.json` holds now: the sidecar without its history.
private struct MainFile: Encodable {
    let version = 2
    let rating: Int
    let flag: Flag
    let adjustments: Adjustments
    let snapshots: [EditSnapshot]

    init(_ s: Sidecar) {
        rating = s.rating; flag = s.flag; adjustments = s.adjustments; snapshots = s.snapshots
    }
}

/// `<name>.history.json`.
struct HistoryFile: Codable {
    var version = 1
    var index: Int
    var steps: [Step]
    /// Each distinct brush stroke once, by key.
    var strokes: [String: BrushStroke]

    struct Step: Codable {
        var id: UUID
        var label: String
        var date: Date
        /// With every mask's strokes taken out (they're in `strokeRefs`).
        var adjustments: Adjustments
        /// Mask id → its strokes, in order, as keys into `strokes`.
        var strokeRefs: [String: [String]]?
    }

    init(_ history: [HistoryStep], index: Int) {
        self.index = index
        var pool: [String: BrushStroke] = [:]
        steps = history.map { step in
            var a = step.adjustments
            var refs: [String: [String]] = [:]
            for i in a.masks.indices where !a.masks[i].strokes.isEmpty {
                refs[a.masks[i].id.uuidString] = a.masks[i].strokes.map { HistoryFile.intern($0, into: &pool) }
                a.masks[i].strokes = []
            }
            return Step(id: step.id, label: step.label, date: step.date, adjustments: a, strokeRefs: refs.isEmpty ? nil : refs)
        }
        strokes = pool
    }

    func historySteps() -> [HistoryStep] {
        steps.map { step in
            var a = step.adjustments
            if let refs = step.strokeRefs {
                for i in a.masks.indices {
                    if let keys = refs[a.masks[i].id.uuidString] { a.masks[i].strokes = keys.compactMap { strokes[$0] } }
                }
            }
            return HistoryStep(id: step.id, label: step.label, date: step.date, adjustments: a)
        }
    }

    /// Adds a stroke to the pool (unless an identical one is there) and returns its key.
    static func intern(_ stroke: BrushStroke, into pool: inout [String: BrushStroke]) -> String {
        let base = String(contentHash(stroke), radix: 36)
        var key = base, n = 1
        while let existing = pool[key] {
            if existing == stroke { return key }
            key = "\(base)-\(n)"   // hash collision: a different stroke
            n += 1
        }
        pool[key] = stroke
        return key
    }

    /// FNV-1a over the stroke's values: stable across launches (Swift's `Hasher` isn't).
    static func contentHash(_ s: BrushStroke) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        @inline(__always) func mix(_ v: UInt64) {
            var x = v
            for _ in 0..<8 { h = (h ^ (x & 0xff)) &* 0x0000_0100_0000_01b3; x >>= 8 }
        }
        mix(s.radius.bitPattern); mix(s.feather.bitPattern); mix(s.flow.bitPattern); mix(s.erase ? 1 : 0)
        mix(UInt64(s.points.count))
        for p in s.points { mix(p.x.bitPattern); mix(p.y.bitPattern) }
        return h
    }
}
