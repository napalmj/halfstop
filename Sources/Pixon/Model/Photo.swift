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
}

/// A named version of a photo's edits that survives history being trimmed or cleared.
struct EditSnapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var date = Date()
    var adjustments: Adjustments
}

/// What gets written to `<folder>/.pixon/<filename>.json`.
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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        rating = (try? c.decodeIfPresent(Int.self, forKey: .rating)) ?? 0
        flag = (try? c.decodeIfPresent(Flag.self, forKey: .flag)) ?? .none
        adjustments = (try? c.decodeIfPresent(Adjustments.self, forKey: .adjustments)) ?? Adjustments()
        history = (try? c.decodeIfPresent([HistoryStep].self, forKey: .history)) ?? []
        historyIndex = (try? c.decodeIfPresent(Int.self, forKey: .historyIndex)) ?? 0
        snapshots = (try? c.decodeIfPresent([EditSnapshot].self, forKey: .snapshots)) ?? []
    }

    /// Nothing worth keeping on disk.
    var isEmpty: Bool {
        rating == 0 && flag == .none && adjustments.isDefault && history.count <= 1 && snapshots.isEmpty
    }
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
        if sidecar.history.isEmpty {
            // Start every photo's history from what's on disk now.
            self.history = [HistoryStep(label: sidecar.adjustments.isDefault ? "Original" : "Opened", adjustments: sidecar.adjustments)]
            self.historyIndex = 0
        } else {
            self.history = sidecar.history
            self.historyIndex = min(max(sidecar.historyIndex, 0), sidecar.history.count - 1)
        }
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

    static func == (lhs: Preset, rhs: Preset) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
