import Foundation

/// A photo's files in `<folder>/.halfstop/`:
/// - `<name>.json`: rating, flag, current adjustments and snapshots. Small; written about
///   0.5 s after any change.
/// - `<name>.history.json`: the edit history, written only when the history itself changes.
///   Every step holds the full adjustments, so brush strokes would repeat in each step;
///   instead each distinct stroke is stored once and steps refer to it by key.
///
/// Older sidecars kept the history inline in `<name>.json`; they still load, and move to
/// the separate file on their next save.
enum SidecarFiles {
    static let folderName = ".halfstop"

    /// `<folder>/.halfstop/`, after moving any sidecars saved under the app's old name.
    static func folder(for photo: URL) -> URL {
        let parent = photo.deletingLastPathComponent()
        let dir = parent.appendingPathComponent(folderName, isDirectory: true)
        LegacyNames.migrateSidecars(in: parent, to: dir)
        return dir
    }

    static func mainURL(for photo: URL) -> URL {
        folder(for: photo).appendingPathComponent(photo.lastPathComponent + ".json")
    }

    static func historyURL(for photo: URL) -> URL {
        folder(for: photo).appendingPathComponent(photo.lastPathComponent + ".history.json")
    }

    /// Every sidecar file a photo can have (for renames and trashing).
    static func all(for photo: URL) -> [URL] { [mainURL(for: photo), historyURL(for: photo)] }

    enum Failure: LocalizedError {
        /// The sidecar folder or file is a link, or isn't what it should be: refused, so a planted
        /// link can't make the app write, delete or move files elsewhere.
        case unsafeLocation(String)

        var errorDescription: String? {
            switch self {
            case .unsafeLocation(let path): "\(path) is a link or not a regular folder; edits there are not read or saved."
            }
        }
    }

    /// Throws unless the photo's sidecar folder is a real folder (or doesn't exist yet) directly
    /// in the photo's folder, and `file`, if it exists, is a regular file rather than a link.
    static func checkSafe(_ file: URL, for photo: URL) throws {
        let parent = photo.deletingLastPathComponent()
        let dir = parent.appendingPathComponent(folderName, isDirectory: true)
        guard file.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path else {
            throw Failure.unsafeLocation(file.path)
        }
        switch LibraryFiles.kind(dir) {
        case .none, .directory: break
        default: throw Failure.unsafeLocation(dir.path)
        }
        switch LibraryFiles.kind(file) {
        case .none, .file: break
        default: throw Failure.unsafeLocation(file.path)
        }
        guard LibraryFiles.isInside(dir, LibraryFiles.canonical(parent)) else { throw Failure.unsafeLocation(dir.path) }
    }

    static func isSafe(_ file: URL, for photo: URL) -> Bool { (try? checkSafe(file, for: photo)) != nil }

    /// The photo's sidecar, keeping every part that can be read. When anything had to be
    /// dropped (or a file can't be read at all), the file is copied aside first, since the next
    /// save rewrites it without the missing parts.
    static func read(for photo: URL) -> Sidecar? {
        let main = mainURL(for: photo), hist = historyURL(for: photo)
        guard isSafe(main, for: photo), let data = try? Data(contentsOf: main) else { return nil }
        let report = DecodeReport()
        guard var sidecar = try? JSONDecoder.reporting(into: report).decode(Sidecar.self, from: data) else {
            FileBackup.keepPartiallyLoaded(main, data: data)
            return nil
        }
        if report.dropped > 0 { FileBackup.keepPartiallyLoaded(main, data: data) }
        if isSafe(hist, for: photo), let data = try? Data(contentsOf: hist) {
            let report = DecodeReport()
            if let file = try? JSONDecoder.reporting(into: report).decode(HistoryFile.self, from: data) {
                sidecar.history = file.historySteps()
                sidecar.historyIndex = file.index
                if report.dropped > 0 { FileBackup.keepPartiallyLoaded(hist, data: data) }
            } else {
                FileBackup.keepPartiallyLoaded(hist, data: data)
            }
        }
        return sidecar
    }

    /// - Parameter history: also write the history file. Ignored (written anyway) when the history
    ///   only exists inline in an older sidecar, so it isn't lost when the main file is rewritten.
    /// Throws when the sidecar folder is unsafe (see `checkSafe`) or a file can't be written.
    static func write(_ sidecar: Sidecar, for photo: URL, history: Bool) throws {
        let main = mainURL(for: photo), hist = historyURL(for: photo)
        try checkSafe(main, for: photo)
        try checkSafe(hist, for: photo)
        let fm = FileManager.default
        if sidecar.isEmpty {
            for url in [main, hist] where LibraryFiles.kind(url) != nil { try fm.removeItem(at: url) }
            return
        }
        try fm.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
        try checkSafe(main, for: photo)   // nothing swapped in while creating it
        let encoder = JSONEncoder()
        let writeHistory = history || (!fm.fileExists(atPath: hist.path) && sidecar.history.count > 1)
        if writeHistory {
            try encoder.encode(HistoryFile(sidecar.history, index: sidecar.historyIndex)).write(to: hist, options: .atomic)
        }
        try encoder.encode(MainFile(sidecar)).write(to: main, options: .atomic)
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

        init(id: UUID, label: String, date: Date, adjustments: Adjustments, strokeRefs: [String: [String]]?) {
            self.id = id; self.label = label; self.date = date; self.adjustments = adjustments; self.strokeRefs = strokeRefs
        }

        init(from decoder: Decoder) throws {
            let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
            id = t.value(.id, UUID())
            label = t.value(.label, "Edit")
            date = t.value(.date, Date())
            adjustments = try t.required(.adjustments)
            strokeRefs = t.dictionary(.strokeRefs)
        }
    }

    // Tolerant decoding: one bad step or stroke is dropped on its own.
    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        version = t.value(.version, 1)
        index = t.value(.index, 0)
        steps = t.array(.steps, default: [])
        strokes = t.dictionary(.strokes) ?? [:]
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
