import Foundation
import Observation

enum Flag: String, Codable {
    case none, pick, reject
}

/// One entry in a photo's edit history: what changed, and the full state after it.
struct HistoryStep: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var date = Date()
    var adjustments: Adjustments
    /// Made by the `halfstop` command rather than in the app. Such a step doesn't count as an edit
    /// by hand for "Learn from my edits" while it's the photo's current step.
    var commandLine = false

    init(id: UUID = UUID(), label: String, date: Date = Date(), adjustments: Adjustments, commandLine: Bool = false) {
        self.id = id; self.label = label; self.date = date; self.adjustments = adjustments; self.commandLine = commandLine
    }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        id = t.value(.id, UUID())
        label = t.value(.label, "Edit")
        date = t.value(.date, Date())
        adjustments = try t.required(.adjustments)
        commandLine = t.value(.commandLine, false)
    }
}

/// A named version of a photo's edits that survives history being trimmed or cleared.
struct EditSnapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var date = Date()
    var adjustments: Adjustments

    init(id: UUID = UUID(), name: String, date: Date = Date(), adjustments: Adjustments) {
        self.id = id; self.name = name; self.date = date; self.adjustments = adjustments
    }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        id = t.value(.id, UUID())
        name = t.value(.name, "Snapshot")
        date = t.value(.date, Date())
        adjustments = try t.required(.adjustments)
    }
}

/// What gets written to `<folder>/.halfstop/<filename>.json`.
struct Sidecar: Codable {
    var version = 1
    var rating = 0
    var flag = Flag.none
    var adjustments = Adjustments()
    var history: [HistoryStep] = []
    /// Which history step is current; steps after it can be redone until the next edit trims them.
    var historyIndex = 0
    var snapshots: [EditSnapshot] = []

    init() {}

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        version = t.value(.version, 1)
        rating = t.value(.rating, 0)
        flag = t.value(.flag, .none)
        adjustments = t.value(.adjustments, Adjustments())
        history = t.array(.history, default: [])
        historyIndex = t.value(.historyIndex, 0)
        snapshots = t.array(.snapshots, default: [])
    }

    /// Nothing worth keeping on disk.
    var isEmpty: Bool {
        rating == 0 && flag == .none && adjustments.isDefault && history.count <= 1 && snapshots.isEmpty
    }

    /// With a history to undo into: one that has none starts from what's on disk now, and the
    /// current step is kept inside it. Photos in the app and the `halfstop` command start the same way.
    mutating func ensureHistory() {
        if history.isEmpty {
            history = [HistoryStep(label: adjustments.isDefault ? "Original" : "Opened", adjustments: adjustments)]
            historyIndex = 0
        } else {
            historyIndex = min(max(historyIndex, 0), history.count - 1)
        }
    }

    /// The step the photo is at.
    var currentStep: HistoryStep? { history.indices.contains(historyIndex) ? history[historyIndex] : nil }
}

@Observable
final class Photo: Identifiable, Hashable {
    let url: URL
    let ref: PhotoRef
    var rating: Int
    var flag: Flag
    var adjustments: Adjustments {
        didSet { revision &+= 1 }
    }
    /// Bumped on every change to `adjustments`: a cheap redraw key (hashing the full
    /// adjustments, brush points included, on every frame was not).
    @ObservationIgnored private(set) var revision = 0
    var history: [HistoryStep]
    var historyIndex: Int
    var snapshots: [EditSnapshot]

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isRAW: Bool { ImageFormats.raw.contains(url.pathExtension.lowercased()) }

    init(url: URL, ref: PhotoRef, sidecar: Sidecar) {
        self.url = url
        self.ref = ref
        self.rating = sidecar.rating
        self.flag = sidecar.flag
        self.adjustments = sidecar.adjustments
        self.snapshots = sidecar.snapshots
        // Start every photo's history from what's on disk now.
        var s = sidecar
        s.ensureHistory()
        self.history = s.history
        self.historyIndex = s.historyIndex
    }

    /// Takes on a sidecar's contents (edits reloaded from disk).
    func adopt(_ sidecar: Sidecar) {
        var s = sidecar
        s.ensureHistory()
        if rating != s.rating { rating = s.rating }
        if flag != s.flag { flag = s.flag }
        if snapshots != s.snapshots { snapshots = s.snapshots }
        if history != s.history { history = s.history }
        if historyIndex != s.historyIndex { historyIndex = s.historyIndex }
        if adjustments != s.adjustments { adjustments = s.adjustments }
    }

    /// Whether its current step was made by the `halfstop` command.
    var atCommandLineStep: Bool {
        history.indices.contains(historyIndex) && history[historyIndex].commandLine
    }

    var sidecar: Sidecar {
        var s = Sidecar()
        s.rating = rating
        s.flag = flag
        s.adjustments = adjustments
        s.history = history
        s.historyIndex = historyIndex
        s.snapshots = snapshots
        return s
    }

    static func == (lhs: Photo, rhs: Photo) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

enum ImageFormats {
    static let raw: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "rwl", "pef", "srw", "x3f", "3fr", "fff", "iiq", "erf", "mos", "mrw",
    ]
    static let raster: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "avif"]
    static let all = raw.union(raster)
}

struct Preset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var adjustments: Adjustments

    init(id: UUID = UUID(), name: String, adjustments: Adjustments) {
        self.id = id; self.name = name; self.adjustments = adjustments
    }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        id = t.value(.id, UUID())
        name = t.value(.name, "Preset")
        adjustments = try t.required(.adjustments)
    }

    static func == (lhs: Preset, rhs: Preset) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
