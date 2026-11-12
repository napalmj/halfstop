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

    init(id: UUID = UUID(), path: String, includeSubfolders: Bool = true, excluded: Set<String> = [], addedAt: Date = Date()) {
        self.id = id; self.path = path; self.includeSubfolders = includeSubfolders
        self.excluded = excluded; self.addedAt = addedAt
    }

    // Tolerant decoding: only `id` and `path` are needed; other fields fall back to defaults.
    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        id = try t.required(.id)
        path = try t.required(.path)
        includeSubfolders = t.value(.includeSubfolders, true)
        excluded = Set(t.array(.excluded, default: [String]()))
        addedAt = t.value(.addedAt, Date())
    }
}

struct PhotoCollection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var members: [PhotoRef] = []
    var createdAt = Date()

    init(id: UUID = UUID(), name: String, members: [PhotoRef] = [], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.members = members; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        id = try t.required(.id)
        name = t.value(.name, "Untitled")
        members = t.array(.members, default: [])
        createdAt = t.value(.createdAt, Date())
    }
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

    init(id: UUID = UUID(), date: Date = Date(), folder: UUID, refs: [PhotoRef], renames: [RenameRecord] = []) {
        self.id = id; self.date = date; self.folder = folder; self.refs = refs; self.renames = renames
    }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        id = t.value(.id, UUID())
        date = t.value(.date, Date())
        folder = try t.required(.folder)
        refs = t.array(.refs, default: [])
        renames = t.array(.renames, default: [])
    }
}

/// The library index: `~/Library/Application Support/Halfstop/catalog.json`.
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

    // Tolerant decoding: one bad folder, collection or entry is dropped on its own instead of
    // emptying the whole list (and `load` keeps a copy of the file when that happens).
    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        version = t.value(.version, 1)
        folders = t.array(.folders, default: [])
        collections = t.array(.collections, default: [])
        fingerprints = t.dictionary(.fingerprints) ?? [:]
        captureDates = t.dictionary(.captureDates) ?? [:]
        lastImport = t.optional(.lastImport)
        targetCollection = t.optional(.targetCollection)
    }

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halfstop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.json")
    }

    static func load(from url: URL = defaultURL) -> Catalog {
        guard let data = try? Data(contentsOf: url) else { return Catalog() }
        let report = DecodeReport()
        let decoder = JSONDecoder.reporting(into: report)
        decoder.dateDecodingStrategy = .iso8601
        guard let c = try? decoder.decode(Catalog.self, from: data) else {
            // Never silently drop a library: keep the unreadable file aside.
            try? FileManager.default.copyItem(at: url, to: url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            return Catalog()
        }
        // Some entries couldn't be read: keep the original before the next save drops them for good.
        if report.dropped > 0 { FileBackup.keepPartiallyLoaded(url, data: data) }
        return c
    }

    func save(to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
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

    enum Kind { case file, directory, link, other }

    /// What's at `url` itself, without following a link there; nil when nothing is.
    static func kind(_ url: URL) -> Kind? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .link
        default: return .other
        }
    }

    /// Whether `url`, with links resolved, is inside the canonical folder `root`. A path that
    /// doesn't exist yet is judged by its (existing) parent folder.
    static func isInside(_ url: URL, _ root: String) -> Bool {
        let r = root.hasSuffix("/") ? String(root.dropLast()) : root
        let path: String
        if kind(url) != nil {
            path = canonical(url)
        } else {
            let name = url.lastPathComponent
            let parent = url.deletingLastPathComponent()
            guard name != ".", name != "..", !name.isEmpty, kind(parent) != nil else { return false }
            path = canonical(parent) + "/" + name
        }
        return path.hasPrefix(r + "/")
    }

    /// Photo files under a folder as sorted relative paths. Skips hidden files (and so `.halfstop/`).
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

    // MARK: Interrupted renames

    static let renameTag = ".halfstop-rename-"
    private static let renameLock = NSLock()
    nonisolated(unsafe) private static var activeRenames = 0

    static func renameStarted() { renameLock.lock(); activeRenames += 1; renameLock.unlock() }
    static func renameEnded() { renameLock.lock(); activeRenames -= 1; renameLock.unlock() }

    /// `IMG_1.jpg` → `IMG_1.halfstop-rename-1a2b3c4d.jpg`: still a visible photo with its extension.
    static func temporaryRenameName(for name: String) -> String {
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        let tag = UUID().uuidString.prefix(8).lowercased()
        return stem + renameTag + tag + (ext.isEmpty ? "" : "." + ext)
    }

    /// The name a temporary rename name came from, or nil if `name` isn't one.
    static func originalName(fromTemporary name: String) -> String? {
        guard let r = name.range(of: renameTag, options: .backwards) else { return nil }
        let rest = name[r.upperBound...]
        let tag = rest.prefix { $0 != "." }
        guard tag.count == 8, tag.allSatisfy(\.isHexDigit), r.lowerBound > name.startIndex else { return nil }
        return String(name[..<r.lowerBound]) + rest.dropFirst(tag.count)
    }

    /// Puts files left under temporary names by a rename that never finished (the app quit or
    /// crashed halfway) back under their original names, when those are free. Skipped while a
    /// rename is running in this app. Returns how many were put back.
    @discardableResult
    static func recoverInterruptedRenames(in folder: URL, recursive: Bool) -> Int {
        renameLock.lock()
        let busy = activeRenames > 0
        renameLock.unlock()
        guard !busy else { return 0 }
        let root = canonical(folder)
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root, isDirectory: true),
                                                     includingPropertiesForKeys: nil, options: options) else { return 0 }
        var restored = 0
        for case let url as URL in e where url.lastPathComponent.contains(renameTag) {
            guard kind(url) == .file, let original = originalName(fromTemporary: url.lastPathComponent) else { continue }
            let dest = url.deletingLastPathComponent().appendingPathComponent(original)
            guard isInside(dest, root), kind(dest) == nil else { continue }
            if (try? FileManager.default.moveItem(at: url, to: dest)) != nil { restored += 1 }
        }
        return restored
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

    /// A file name part that can't hide the file or disguise it: no leading dots (hidden files),
    /// no control, format or direction-override characters, no path separators or colons, no spaces,
    /// and at most `maxBytes` UTF-8 bytes (file names are limited to 255).
    static func cleanName(_ raw: String, maxBytes: Int) -> String {
        var out = ""
        for ch in raw.unicodeScalars {
            switch ch.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                continue
            default:
                break
            }
            switch ch {
            case "/", ":", "\\": out.unicodeScalars.append("-")
            default:
                if ch.properties.isWhitespace { out.unicodeScalars.append("-") } else { out.unicodeScalars.append(ch) }
            }
        }
        while out.hasPrefix(".") || out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") || out.hasSuffix(".") { out.removeLast() }
        while out.utf8.count > maxBytes { out.removeLast() }
        return out
    }

    /// New relative paths (same directories, same extensions) for files ordered by capture time.
    static func plan(_ files: [(path: String, date: Date)], pattern: RenamePattern, customName: String) -> [String: String] {
        let ordered = files.sorted { $0.date == $1.date ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : $0.date < $1.date }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let slug = cleanName(customName, maxBytes: 100)
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
            newStem = cleanName(newStem, maxBytes: 200)
            if newStem.isEmpty { newStem = "photo-\(seq)" }
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
/// Ignores changes inside `.halfstop/` so saving edits doesn't trigger rescans.
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
            let relevant = paths.filter { !$0.contains("/" + SidecarFiles.folderName) && !$0.contains("/" + LegacyNames.sidecarFolder) }
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
