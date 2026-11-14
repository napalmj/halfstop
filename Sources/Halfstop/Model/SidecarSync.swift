import Foundation
import Darwin

// Keeping sidecars consistent when more than one program writes them: the app and the
// `halfstop` command (or several runs of it). Each writer holds the photo folder's sidecar lock
// while it reads and rewrites a photo's files, the app notices files that changed on disk without
// it, and edits made on both sides are merged rather than overwritten (`SidecarMerge`).

/// One sidecar file as it was on disk: where it was (inode, size, modification time) and a hash of
/// its content. The stamp is a cheap "unchanged" check; the hash decides when the stamp differs.
struct SidecarFileState: Equatable, Sendable {
    struct Stamp: Equatable, Sendable {
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        /// The regular file at `url` (not following a link); nil when there's none.
        init?(_ url: URL) {
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            seconds = st.st_mtimespec.tv_sec
            nanoseconds = st.st_mtimespec.tv_nsec
        }
    }

    let stamp: Stamp
    let hash: UInt64

    init(stamp: Stamp, hash: UInt64) { self.stamp = stamp; self.hash = hash }

    /// Just written: `data` is what's in it.
    init?(url: URL, data: Data) {
        guard let stamp = Stamp(url) else { return nil }
        self.init(stamp: stamp, hash: Self.hash(data))
    }

    /// FNV-1a over the bytes and the length.
    static func hash(_ data: Data) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { raw in
            for b in raw { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        }
        return (h ^ UInt64(data.count)) &* 0x0000_0100_0000_01b3
    }
}

/// Both of a photo's sidecar files as they were on disk (nil: no such file).
struct SidecarRevision: Equatable, Sendable {
    var main: SidecarFileState?
    var history: SidecarFileState?

    static let none = SidecarRevision(main: nil, history: nil)

    /// Same content (files touched or rewritten identically count as the same).
    func sameContent(as other: SidecarRevision) -> Bool {
        main?.hash == other.main?.hash && history?.hash == other.history?.hash
    }
}

/// The sidecar files' bytes as read, with their revision.
struct SidecarSnapshot: Sendable {
    var main: Data?
    var history: Data?
    var revision: SidecarRevision
    /// The file's stamp matched the known state, so it wasn't read (its bytes are nil).
    var reusedMain = false
    var reusedHistory = false
}

// MARK: - Lock

/// A lock per photo folder, shared by the app and every run of the `halfstop` command: `flock` on
/// the folder's `.halfstop` directory. It's held only while a photo's files are read and rewritten
/// (milliseconds), so two writers never interleave and a read never sees one file new and the other
/// old. It also excludes threads of one process, since each holder opens the folder itself.
enum SidecarLock {
    /// How long to wait for another writer before giving up.
    nonisolated(unsafe) static var timeout: TimeInterval = 10

    enum Failure: LocalizedError {
        case busy(String)
        var errorDescription: String? {
            switch self {
            case .busy(let path): "Another program kept the edits in \(path) locked for too long. Try again."
            }
        }
    }

    /// Runs `body` holding the lock for `photo`'s folder. With `create`, makes the sidecar folder
    /// first if needed; without it, a folder with no sidecar folder yet runs `body` unlocked (there's
    /// nothing to read). Where locks aren't supported (some network volumes), runs unlocked.
    static func with<T>(_ photo: URL, exclusive: Bool, create: Bool, _ body: () throws -> T) throws -> T {
        let dir = SidecarFiles.folder(for: photo)
        switch LibraryFiles.kind(dir) {
        case nil:
            guard create else { return try body() }
            try SidecarFiles.checkSafe(dir.appendingPathComponent("x"), for: photo)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard LibraryFiles.kind(dir) == .directory else { throw SidecarFiles.Failure.unsafeLocation(dir.path) }
        case .directory:
            break
        default:
            throw SidecarFiles.Failure.unsafeLocation(dir.path)
        }
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            let err = errno
            if err == EINTR { continue }
            guard err == EWOULDBLOCK else { return try body() }   // ENOTSUP and the like: no locking here
            guard Date() < deadline else { throw Failure.busy(dir.path) }
            usleep(2_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

// MARK: - Fields from newer versions

/// Carries over fields this version of Halfstop doesn't know when it rewrites a file it read, so
/// the `halfstop` command never drops what a newer app wrote. "Unknown" means: in the file as read,
/// but missing from what this version writes back for it unchanged (`roundTrip`). Those values are
/// put back at the same place in the new file, if that place still exists (array elements are
/// matched by their `id`). Values this version knows are never resurrected.
enum UnknownFields {
    enum Kind { case main, history }

    private enum Step: Hashable {
        case key(String)
        case id(String)
        case index(Int)
    }

    static func carry(from old: Data, roundTrip: (Data) -> Data?, into new: Data, kind: Kind) -> Data {
        guard let trip = roundTrip(old),
              let original = try? JSONSerialization.jsonObject(with: old),
              let known = try? JSONSerialization.jsonObject(with: trip) else { return new }
        var lost: [([Step], Any)] = []
        collect(original, known, path: [], into: &lost)
        lost.removeAll { !restorable($0.0, kind: kind) }
        guard !lost.isEmpty, var target = try? JSONSerialization.jsonObject(with: new) else { return new }
        for (path, value) in lost { target = insert(value, at: path[...], into: target) ?? target }
        guard JSONSerialization.isValidJSONObject(target),
              let out = try? JSONSerialization.data(withJSONObject: target, options: [.sortedKeys]) else { return new }
        return out
    }

    /// The main file's inline history moved to the history file; the history file's stroke pool is
    /// rebuilt on every write (unused strokes are meant to go).
    private static func restorable(_ path: [Step], kind: Kind) -> Bool {
        switch kind {
        case .main: return !(path.count == 1 && (path[0] == .key("history") || path[0] == .key("historyIndex")))
        case .history: return !(path.count == 2 && path[0] == .key("strokes"))
        }
    }

    private static func elementID(_ x: Any) -> String? { (x as? [String: Any])?["id"] as? String }

    private static func collect(_ original: Any, _ known: Any, path: [Step], into lost: inout [([Step], Any)]) {
        if let o = original as? [String: Any], let k = known as? [String: Any] {
            for (key, value) in o {
                if let kv = k[key] { collect(value, kv, path: path + [.key(key)], into: &lost) } else { lost.append((path + [.key(key)], value)) }
            }
        } else if let o = original as? [Any], let k = known as? [Any] {
            let ids = o.map(elementID)
            if !o.isEmpty, ids.allSatisfy({ $0 != nil }) {
                let byID = Dictionary(k.compactMap { x in elementID(x).map { ($0, x) } }, uniquingKeysWith: { a, _ in a })
                for (x, id) in zip(o, ids) {
                    if let kx = byID[id!] { collect(x, kx, path: path + [.id(id!)], into: &lost) }
                }
            } else if o.count == k.count {
                for i in o.indices { collect(o[i], k[i], path: path + [.index(i)], into: &lost) }
            }
        }
    }

    /// `target` with `value` put at `path`; nil when the place no longer exists (or is taken).
    private static func insert(_ value: Any, at path: ArraySlice<Step>, into target: Any) -> Any? {
        guard let first = path.first else { return nil }
        let rest = path.dropFirst()
        switch first {
        case .key(let key):
            guard var dict = target as? [String: Any] else { return nil }
            if rest.isEmpty {
                guard dict[key] == nil else { return nil }
                dict[key] = value
            } else {
                guard let inner = dict[key], let updated = insert(value, at: rest, into: inner) else { return nil }
                dict[key] = updated
            }
            return dict
        case .id(let id):
            guard var array = target as? [Any], let i = array.firstIndex(where: { elementID($0) == id }),
                  !rest.isEmpty, let updated = insert(value, at: rest, into: array[i]) else { return nil }
            array[i] = updated
            return array
        case .index(let i):
            guard var array = target as? [Any], array.indices.contains(i),
                  !rest.isEmpty, let updated = insert(value, at: rest, into: array[i]) else { return nil }
            array[i] = updated
            return array
        }
    }
}

// MARK: - Merging

/// The rule when a photo's edits changed on disk (the `halfstop` command, say) while the app also
/// had changes of its own for it that weren't saved yet. Nothing is dropped:
/// - With no changes in the app since it last read or wrote the files, the version on disk is taken
///   as is (history included).
/// - Otherwise the version on disk is taken, with its history, and the app's changes are applied on
///   top as one new history step: each setting the app changed gets the app's value, every other
///   setting keeps the disk's value. Undo steps back to exactly the disk's version. (The app's own
///   steps since the last save are folded into that one step.)
/// Rating, flag and snapshots merge the same way.
enum SidecarMerge {
    struct Result {
        var sidecar: Sidecar
        /// The app had changes of its own: the result differs from the disk's version and must be saved.
        var keptLocalChanges: Bool
    }

    static func merge(base: Sidecar, ours: Sidecar, theirs: Sidecar, historyLimit: Int) -> Result {
        var theirs = theirs
        theirs.ensureHistory()
        guard !same(base, ours) else { return Result(sidecar: theirs, keptLocalChanges: false) }
        var out = theirs
        out.rating = ours.rating != base.rating ? ours.rating : theirs.rating
        out.flag = ours.flag != base.flag ? ours.flag : theirs.flag
        out.snapshots = mergeSnapshots(base: base.snapshots, ours: ours.snapshots, theirs: theirs.snapshots)
        let adjustments = ours.adjustments == base.adjustments ? theirs.adjustments
            : mergeAdjustments(base: base.adjustments, ours: ours.adjustments, theirs: theirs.adjustments)
        if adjustments != theirs.adjustments {
            var history = Array(theirs.history.prefix(theirs.historyIndex + 1))
            history.append(HistoryStep(label: HistoryLabel.describe(from: theirs.adjustments, to: adjustments), adjustments: adjustments))
            if history.count > historyLimit { history = [history[0]] + history.suffix(historyLimit - 1) }
            out.history = history
            out.historyIndex = history.count - 1
            out.adjustments = adjustments
        }
        return Result(sidecar: out, keptLocalChanges: true)
    }

    /// Same edits, rating, flag, snapshots and history position.
    static func same(_ a: Sidecar, _ b: Sidecar) -> Bool {
        a.adjustments == b.adjustments && a.rating == b.rating && a.flag == b.flag && a.snapshots == b.snapshots
            && a.historyIndex == b.historyIndex && a.history.map(\.id) == b.history.map(\.id)
    }

    /// Setting by setting (JSON keys, nested objects key by key; lists such as masks or the curve
    /// as a whole): what the app changed comes from `ours`, everything else from `theirs`.
    static func mergeAdjustments(base: Adjustments, ours: Adjustments, theirs: Adjustments) -> Adjustments {
        let encoder = JSONEncoder()
        guard let b = try? JSONSerialization.jsonObject(with: encoder.encode(base)),
              let o = try? JSONSerialization.jsonObject(with: encoder.encode(ours)),
              let t = try? JSONSerialization.jsonObject(with: encoder.encode(theirs)) else { return ours }
        let merged = merge3(b, o, t)
        guard JSONSerialization.isValidJSONObject(merged), let data = try? JSONSerialization.data(withJSONObject: merged),
              let out = try? JSONDecoder().decode(Adjustments.self, from: data) else { return ours }
        return out
    }

    private static func merge3(_ base: Any?, _ ours: Any?, _ theirs: Any?) -> Any {
        if let b = base as? [String: Any], let o = ours as? [String: Any], let t = theirs as? [String: Any] {
            var out: [String: Any] = [:]
            for key in Set(o.keys).union(t.keys) {
                let changedByUs = !equal(b[key], o[key])
                if changedByUs {
                    if o[key] != nil { out[key] = merge3(b[key], o[key], t[key]) }
                } else if let tv = t[key] {
                    out[key] = tv
                }
            }
            return out
        }
        return equal(base, ours) ? (theirs ?? ours ?? NSNull()) : (ours ?? NSNull())
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return (x as AnyObject).isEqual(y as AnyObject)
        default: return false
        }
    }

    private static func mergeSnapshots(base: [EditSnapshot], ours: [EditSnapshot], theirs: [EditSnapshot]) -> [EditSnapshot] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oursByID = Dictionary(ours.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [EditSnapshot] = []
        for s in theirs {
            if baseByID[s.id] != nil && oursByID[s.id] == nil { continue }               // deleted in the app
            if let mine = oursByID[s.id], let was = baseByID[s.id], mine != was { out.append(mine) } else { out.append(s) }
        }
        let present = Set(out.map(\.id))
        out += ours.filter { baseByID[$0.id] == nil && !present.contains($0.id) }         // added in the app
        return out
    }
}

// MARK: - What the app last read or wrote

/// A change found on disk that the app hasn't taken in yet.
struct ExternalSidecarChange: Sendable {
    let url: URL
    let sidecar: Sidecar
    let revision: SidecarRevision
    /// `SidecarSync.epoch` after this change was found; older pending saves are dropped.
    let epoch: Int
}

/// Per photo: the revision of its files the app last read or wrote, the edits that held (the base
/// for merging), and an epoch that moves on whenever a change on disk is found, so saves scheduled
/// before it are dropped instead of overwriting it. Thread-safe; checks and saves run in the
/// background, holding `SidecarLock`.
final class SidecarSync: @unchecked Sendable {
    struct State {
        var revision: SidecarRevision
        var base: Sidecar
    }

    private var states: [URL: State] = [:]
    private var epochs: [URL: Int] = [:]
    private let lock = NSLock()

    func state(_ url: URL) -> State? { lock.withLock { states[url] } }
    func epoch(_ url: URL) -> Int { lock.withLock { epochs[url] ?? 0 } }

    func record(_ url: URL, revision: SidecarRevision, base: Sidecar) {
        lock.withLock { states[url] = State(revision: revision, base: base) }
    }

    /// A change on disk was found: saves scheduled before now are stale.
    func bump(_ url: URL) -> Int {
        lock.withLock {
            let e = (epochs[url] ?? 0) + 1
            epochs[url] = e
            return e
        }
    }

    /// Same content, new stamps (a file was touched): remember them, unless the state moved on.
    func refreshStamps(_ url: URL, from old: SidecarRevision, to new: SidecarRevision) {
        lock.withLock {
            guard var s = states[url], s.revision == old else { return }
            s.revision = new
            states[url] = s
        }
    }

    func forget(_ url: URL) { lock.withLock { states[url] = nil } }
    func keep(only urls: Set<URL>) { lock.withLock { states = states.filter { urls.contains($0.key) } } }

    enum SaveOutcome: Sendable {
        case saved
        case failed(Error)
        /// The files changed on disk since the app last read or wrote them: nothing was written.
        case changedOnDisk(ExternalSidecarChange)
        /// A change on disk was found after this save was scheduled: dropped.
        case superseded
    }

    /// Writes the app's version of a photo's sidecar, unless the files changed on disk since the app
    /// last read or wrote them (then it reports the change instead), or a change was found after this
    /// save was scheduled (`epoch`).
    func save(_ sidecar: Sidecar, for url: URL, history: Bool, epoch: Int) -> SaveOutcome {
        do {
            return try SidecarLock.with(url, exclusive: true, create: !sidecar.isEmpty) {
                guard self.epoch(url) == epoch else { return .superseded }
                if let known = state(url), let change = changeOnDisk(url, known: known) { return .changedOnDisk(change) }
                // The files are as last known (just checked): a history file left as is needn't be read again.
                let known = state(url).map { SidecarSnapshot(main: nil, history: nil, revision: $0.revision) }
                let revision = try SidecarFiles.write(sidecar, for: url, history: history, keepingUnknownFrom: known)
                record(url, revision: revision, base: sidecar)
                return .saved
            }
        } catch {
            return .failed(error)
        }
    }

    /// Looks for a change on disk the app hasn't taken in (FSEvents saw the photo's sidecar change).
    func check(_ url: URL) -> ExternalSidecarChange? {
        // A photo that's gone (renamed, trashed) is the library's business, not a change of edits.
        guard state(url) != nil, LibraryFiles.kind(url) == .file else { return nil }
        return try? SidecarLock.with(url, exclusive: false, create: false) {
            guard let known = state(url) else { return nil }
            return changeOnDisk(url, known: known)
        }
    }

    /// Call holding the lock.
    private func changeOnDisk(_ url: URL, known: State) -> ExternalSidecarChange? {
        let quick = SidecarFiles.snapshot(for: url, known: known.revision)
        if quick.revision == known.revision { return nil }
        if quick.revision.sameContent(as: known.revision) {
            refreshStamps(url, from: known.revision, to: quick.revision)
            return nil
        }
        let disk = SidecarFiles.snapshot(for: url)
        let decoded = SidecarFiles.decode(disk, for: url)
        if disk.main != nil, decoded == nil {
            // Unreadable (it was copied aside by `decode`): keep the app's version, which the next save writes.
            refreshStamps(url, from: known.revision, to: disk.revision)
            return nil
        }
        // No main file: the edits were removed on disk (reset).
        return ExternalSidecarChange(url: url, sidecar: decoded ?? Sidecar(), revision: disk.revision, epoch: bump(url))
    }
}
