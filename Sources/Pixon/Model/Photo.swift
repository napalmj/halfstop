import Foundation
import Observation

enum Flag: String, Codable {
    case none, pick, reject
}

/// What gets written to `<folder>/.pixon/<filename>.json`.
struct Sidecar: Codable {
    var version = 1
    var rating = 0
    var flag = Flag.none
    var adjustments = Adjustments()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        rating = (try? c.decodeIfPresent(Int.self, forKey: .rating)) ?? 0
        flag = (try? c.decodeIfPresent(Flag.self, forKey: .flag)) ?? .none
        adjustments = (try? c.decodeIfPresent(Adjustments.self, forKey: .adjustments)) ?? Adjustments()
    }
}

@Observable
final class Photo: Identifiable, Hashable {
    let url: URL
    let ref: PhotoRef
    var rating: Int
    var flag: Flag
    var adjustments: Adjustments

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isRAW: Bool { ImageFormats.raw.contains(url.pathExtension.lowercased()) }

    init(url: URL, ref: PhotoRef, sidecar: Sidecar) {
        self.url = url
        self.ref = ref
        self.rating = sidecar.rating
        self.flag = sidecar.flag
        self.adjustments = sidecar.adjustments
    }

    var sidecar: Sidecar {
        var s = Sidecar()
        s.rating = rating
        s.flag = flag
        s.adjustments = adjustments
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
