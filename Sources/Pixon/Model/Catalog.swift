import Foundation
import CryptoKit
import ImageIO
import CoreServices

/// Stable identity for a photo: which imported folder it lives in, and its path inside it.
/// Survives the folder being moved (only the folder's path changes).
struct PhotoRef: Codable, Hashable {
    var folder: UUID
    var path: String

    var key: String { "\(folder.uuidString)/\(path)" }
}

/// A directory the user imported. Photos are referenced in place, never copied.
struct CatalogFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var includeSubfolders = true
    /// Relative paths skipped at import because they duplicated photos already in the library.
    var excluded: Set<String> = []
    var addedAt = Date()

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent }
    var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

struct PhotoCollection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var members: [PhotoRef] = []
    var createdAt = Date()
}

struct RenameRecord: Codable, Hashable {
    /// Relative paths inside the import's folder.
    var from: String
    var to: String
}

struct ImportRecord: Codable, Hashable {
    var id = UUID()
    var date = Date()
    var folder: UUID
    var refs: [PhotoRef]
    var renames: [RenameRecord] = []
}

/// The library index: `~/Library/Application Support/Pixon/catalog.json`.
struct Catalog: Codable {
    var version = 1
    var folders: [CatalogFolder] = []
    var collections: [PhotoCollection] = []
    /// PhotoRef.key → content fingerprint, for duplicate detection.
    var fingerprints: [String: String] = [:]
    /// PhotoRef.key → when the photo was taken (EXIF, else file date), for sorting.
    var captureDates: [String: Date] = [:]
    var lastImport: ImportRecord?
    var targetCollection: UUID?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        folders = (try? c.decodeIfPresent([CatalogFolder].self, forKey: .folders)) ?? []
        collections = (try? c.decodeIfPresent([PhotoCollection].self, forKey: .collections)) ?? []
        fingerprints = (try? c.decodeIfPresent([String: String].self, forKey: .fingerprints)) ?? [:]
        captureDates = (try? c.decodeIfPresent([String: Date].self, forKey: .captureDates)) ?? [:]
        lastImport = try? c.decodeIfPresent(ImportRecord.self, forKey: .lastImport)
        targetCollection = try? c.decodeIfPresent(UUID.self, forKey: .targetCollection)
    }

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pixon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.json")
    }

    static func load(from url: URL = defaultURL) -> Catalog {
        guard let data = try? Data(contentsOf: url) else { return Catalog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let c = try? decoder.decode(Catalog.self, from: data) else {
            // Never silently drop a library: keep the unreadable file aside.
            try? FileManager.default.copyItem(at: url, to: url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            return Catalog()
        }
        return c
    }

    func save(to url: URL = defaultURL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }

    func folder(_ id: UUID) -> CatalogFolder? { folders.first { $0.id == id } }

    /// Drops every reference to photos that are gone (moved to the Trash).
    mutating func forget(_ refs: Set<PhotoRef>) {
        for i in collections.indices { collections[i].members.removeAll { refs.contains($0) } }
        for r in refs { fingerprints[r.key] = nil; captureDates[r.key] = nil }
        if var record = lastImport {
            record.refs.removeAll { refs.contains($0) }
            lastImport = record
        }
    }

    /// Rewrites every reference to a renamed photo (collections, fingerprints, last import).
    mutating func rename(_ from: PhotoRef, to: PhotoRef) {
        for i in collections.indices {
            collections[i].members = collections[i].members.map { $0 == from ? to : $0 }
        }
        if let fp = fingerprints.removeValue(forKey: from.key) { fingerprints[to.key] = fp }
        if var record = lastImport {
            record.refs = record.refs.map { $0 == from ? to : $0 }
            lastImport = record
        }
    }
}

// MARK: - File helpers

enum LibraryFiles {
    /// Canonical absolute path (resolves /tmp → /private/tmp and the like).
    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Photo files under a folder as sorted relative paths. Skips hidden files (and so `.pixon/`).
    static func enumerate(_ folder: URL, recursive: Bool) -> [String] {
        let root = canonical(folder)
        let base = URL(fileURLWithPath: root, isDirectory: true)
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey], options: options) else { return [] }
        var out: [String] = []
        for case let url as URL in e where ImageFormats.all.contains(url.pathExtension.lowercased()) {
            let p = canonical(url)
            guard p.hasPrefix(root + "/") else { continue }
            out.append(String(p.dropFirst(root.count + 1)))
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Size + hash of the first 256 KB: cheap, and still matches renamed copies.
    static func fingerprint(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        let digest = SHA256.hash(data: head).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(size)-\(digest)"
    }

    /// When the photo was taken (EXIF), falling back to the file's dates.
    static func captureDate(_ url: URL) -> Date {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: s) { return d }
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }
}

// MARK: - Rename patterns

enum RenamePattern: String, CaseIterable, Identifiable, Codable {
    case dateSequence, nameSequence, dateOriginal
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateSequence: "Date-sequence"
        case .nameSequence: "Custom name-sequence"
        case .dateOriginal: "Date-original name"
        }
    }

    /// New relative paths (same directories, same extensions) for files ordered by capture time.
    static func plan(_ files: [(path: String, date: Date)], pattern: RenamePattern, customName: String) -> [String: String] {
        let ordered = files.sorted { $0.date == $1.date ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : $0.date < $1.date }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let slug = customName.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let name = slug.isEmpty ? "photo" : slug
        let width = max(3, String(ordered.count).count)
        var taken = Set<String>()
        var out: [String: String] = [:]
        for (i, f) in ordered.enumerated() {
            let url = URL(fileURLWithPath: f.path)
            let dir = (f.path as NSString).deletingLastPathComponent
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            let seq = String(format: "%0\(width)d", i + 1)
            var newStem: String
            switch pattern {
            case .dateSequence: newStem = "\(df.string(from: f.date))-\(seq)"
            case .nameSequence: newStem = "\(name)-\(seq)"
            case .dateOriginal: newStem = "\(df.string(from: f.date))-\(stem)"
            }
            var candidate = (dir.isEmpty ? "" : dir + "/") + newStem + (ext.isEmpty ? "" : "." + ext)
            var n = 2
            while taken.contains(candidate.lowercased()) {
                candidate = (dir.isEmpty ? "" : dir + "/") + "\(newStem)-\(n)" + (ext.isEmpty ? "" : "." + ext)
                n += 1
            }
            taken.insert(candidate.lowercased())
            out[f.path] = candidate
        }
        return out
    }
}

// MARK: - Folder watching

/// Calls back (on the main queue, debounced by FSEvents) when anything under the watched folders changes.
/// Ignores changes inside `.pixon/` so saving edits doesn't trigger rescans.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(_ paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            let relevant = paths.filter { !$0.contains("/.pixon") }
            if !relevant.isEmpty { me.onChange(relevant) }
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
