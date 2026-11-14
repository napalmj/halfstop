import Foundation
import Observation
import AppKit

enum ViewMode { case library, edit }

enum PanelTab: String { case quick, detailed }

/// Painting refinements onto a non-brush mask.
enum RefineMode { case add, subtract }

enum LibrarySource: Hashable {
    case all, lastImport
    case folder(UUID)
    case collection(UUID)
}

enum SortOrder: String, CaseIterable, Identifiable {
    case folder, fileName, captureTime, rating
    var id: String { rawValue }
    var label: String {
        switch self {
        case .folder: "Folder order"
        case .fileName: "File name"
        case .captureTime: "Capture time"
        case .rating: "Rating"
        }
    }
}

enum EditsFilter: String, CaseIterable, Identifiable {
    case any, edited, unedited
    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: "Edited or not"
        case .edited: "Edited only"
        case .unedited: "Not edited"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, picks, unflagged, rejected
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .picks: "Picks"
        case .unflagged: "Unflagged"
        case .rejected: "Rejected"
        }
    }
}

/// How an auto action ended.
enum AutoOutcome: Equatable, Sendable {
    /// Applied as one history step.
    case applied
    /// Measured, but it would change nothing (no step added).
    case unchanged
    /// Auto straighten found no horizon it trusts (shown as a hint).
    case noHorizon
    /// Dropped: the user moved to another photo or changed the edits meanwhile.
    case stale
    /// The photo couldn't be read.
    case unreadable
}

/// An auto action in flight, for the progress state on its chip.
struct AutoRun: Equatable {
    let url: URL
    let kind: AutoKind
    let id: UUID
}

@MainActor
@Observable
final class LibraryStore {
    // Library contents
    /// Mutated only by the store and its Importer extension.
    var catalog = Catalog()
    /// Kept in the chosen sort order (see `sorted`); assign through `sorted(_:)` when replacing.
    var photos: [Photo] = [] {
        didSet {
            photoPosition = Dictionary(photos.enumerated().map { ($1.ref, $0) }, uniquingKeysWith: { a, _ in a })
            photoByRef = Dictionary(photos.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
            photoByURL = Dictionary(photos.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }
    @ObservationIgnored private var photoByRef: [PhotoRef: Photo] = [:]
    /// Index in `photos`, to put collections in the same order.
    @ObservationIgnored private var photoPosition: [PhotoRef: Int] = [:]
    /// Position of each photo in the last folder scan (folders in turn, Finder path order).
    @ObservationIgnored private var scanOrder: [URL: Int] = [:]
    var sortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .folder {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder"); resort() }
    }
    var sortDescending = UserDefaults.standard.bool(forKey: "sortDescending") {
        didSet { UserDefaults.standard.set(sortDescending, forKey: "sortDescending"); resort() }
    }
    /// Lookup for `current`, which every slider reads on every tick (a scan was O(library)).
    /// Observed, so views reading `current` still update when the library changes.
    private var photoByURL: [URL: Photo] = [:]
    private(set) var isLoading = false
    var source: LibrarySource = .all {
        didSet { if oldValue != source { selection = []; keepCurrentVisible() } }
    }
    var showSidebar = true
    /// The history panel on the left of the editor.
    var showHistory = UserDefaults.standard.object(forKey: "showHistory") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showHistory, forKey: "showHistory") }
    }
    var showImport = false
    /// Folder to prefill in the import sheet (e.g. from drag and drop).
    var importPrefill: URL?
    @ObservationIgnored let catalogURL: URL
    @ObservationIgnored private var watcher: FolderWatcher?
    /// What each photo's sidecar files held when the app last read or wrote them, so a change made
    /// outside the app (the `halfstop` command) is noticed, shown and never overwritten.
    nonisolated let sync = SidecarSync()
    @ObservationIgnored private var reloadPending = false

    // Navigation
    var mode: ViewMode = .library
    var currentID: URL?
    /// Photos waiting on the "Move to Trash" confirmation.
    var trashRequest: TrashRequest?
    /// Files that couldn't be moved to the Trash (shown in an alert).
    var trashFailures: [String] = []
    var selection: Set<URL> = []
    private var selectionAnchor: URL?

    // Filtering
    var filter: LibraryFilter = .all { didSet { keepCurrentVisible() } }
    var minRating = 0 { didSet { keepCurrentVisible() } }
    var hideRejected = false { didSet { keepCurrentVisible() } }
    var editsFilter: EditsFilter = .any { didSet { keepCurrentVisible() } }

    // Editor state
    var isCropping = false { didSet { if isCropping { activeMaskID = nil } } }
    var showBefore = false
    /// Paints blown highlights red and crushed shadows blue on the preview (J).
    var showClipping = false
    /// The next click on the photo sets white balance from that spot (W).
    var pickingWhite = false
    /// The auto action measuring right now, if any (its chip shows progress).
    private(set) var autoRun: AutoRun?
    /// Move to the next photo after rating or flagging one (⇧ with the key does it once).
    var autoAdvance = UserDefaults.standard.bool(forKey: "autoAdvance") {
        didSet { UserDefaults.standard.set(autoAdvance, forKey: "autoAdvance") }
    }
    var thumbnailSize: Double = 200

    // Learn from my edits
    /// ✦ Auto adapts to the user's own edits (Settings). On by default.
    var learnFromEdits = UserDefaults.standard.object(forKey: LibraryStore.learnFromEditsKey) as? Bool ?? true {
        didSet {
            guard learnFromEdits != oldValue else { return }
            UserDefaults.standard.set(learnFromEdits, forKey: Self.learnFromEditsKey)
            rebuildStyleModel()
        }
    }
    nonisolated static let learnFromEditsKey = "learnFromEdits"
    /// Edited photos ✦ Auto learns from, updated one photo at a time (never a catalog rescan per click).
    @ObservationIgnored var styleModel = StyleModel()
    /// Whether the model has enough edited photos to act (observed, unlike the model itself).
    private(set) var styleActive = false
    @ObservationIgnored private var pendingStyleSamples: [URL: DispatchWorkItem] = [:]
    @ObservationIgnored private var pendingCatalogSave: DispatchWorkItem?
    var panelTab: PanelTab = .quick { didSet { if panelTab == .quick { activeMaskID = nil } } }
    /// Mask currently being edited; nil = whole photo.
    var activeMaskID: UUID? {
        didSet {
            if activeMaskID != nil { isCropping = false }
            if activeMaskID != oldValue { refineMode = nil; activeShapeID = nil }
        }
    }
    /// Which shape of the active mask the handles edit; nil = the mask's own shape.
    var activeShapeID: UUID?
    var refineMode: RefineMode?
    var showMaskOverlay = false
    /// True while a mask is being painted or dragged.
    var maskInteracting = false
    // Brush tool
    var brushSize: Double = 0.04
    var brushFeather: Double = 0.6
    var brushFlow: Double = 1
    var brushErase = false
    // Sheets & layout
    var showExport = false
    var showSavePreset = false
    var gridColumns = 4

    // Presets & clipboard
    private(set) var presets: [Preset] = []
    private(set) var clipboard: Adjustments?

    // Undo (per photo, reset when switching photos)
    /// Changes waiting to settle into a history step.
    @ObservationIgnored private var pendingCommits: [URL: DispatchWorkItem] = [:]

    @ObservationIgnored private var pendingSaves: [URL: DispatchWorkItem] = [:]
    @ObservationIgnored private var pendingTokens: [URL: UUID] = [:]
    /// Photos whose history changed since their last save.
    @ObservationIgnored private var historyDirty: Set<URL> = []
    /// Photos with edits not yet written to their sidecar (they save ~0.5 s after a change).
    private(set) var unsavedCount = 0
    private(set) var lastSaved: Date?
    /// Briefly true after ⌘S, to confirm the save.
    var savedFlash = false
    /// Photos whose last save failed → why. Their edits stay in memory, still count as unsaved,
    /// and are retried (every 30 s, on any change to them, on ⌘S and on "Try again").
    private(set) var failedSaves: [URL: String] = [:]
    /// Library files ("Library index", "Presets") whose last save failed → why.
    private(set) var failedLibraryFiles: [String: String] = [:]
    /// The save problems popover in the top bar.
    var showSaveProblems = false
    /// What each failed save tried to write, so it can be retried even after its photo left the
    /// list (its card was ejected, say).
    @ObservationIgnored private var failedSnapshots: [URL: (sidecar: Sidecar, history: Bool)] = [:]
    @ObservationIgnored private var retryTimer: Timer?
    /// The app's own store (the self-test makes others), for the quit check.
    static weak var appStore: LibraryStore?

    init(catalogURL: URL = Catalog.defaultURL, watch: Bool = true) {
        self.catalogURL = catalogURL
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSaves() }
        }
        loadPresets()
        catalog = Catalog.load(from: catalogURL)
        // One-time migration from the folder-at-a-time version.
        if catalogURL == Catalog.defaultURL, catalog.folders.isEmpty, let path = UserDefaults.standard.string(forKey: "lastFolder"),
           FileManager.default.fileExists(atPath: path) {
            catalog.folders.append(CatalogFolder(path: LibraryFiles.canonical(URL(fileURLWithPath: path)), includeSubfolders: false))
            saveCatalog()
        }
        if watch {
            watcher = FolderWatcher(onChange: { [weak self] paths in
                MainActor.assumeIsolated { self?.scheduleReload(changed: paths) }
            }, onSidecarChange: { [weak self] paths in
                MainActor.assumeIsolated { self?.sidecarsChanged(paths) }
            })
        }
        reload()
    }

    var hasLibrary: Bool { !catalog.folders.isEmpty }

    func saveCatalog() {
        do {
            try catalog.save(to: catalogURL)
            failedLibraryFiles["Library index"] = nil
        } catch {
            failedLibraryFiles["Library index"] = Self.describeSaveError(error)
        }
        updateRetryTimer()
    }

    // MARK: - Derived

    /// Everything in the chosen source (folder, collection…), before filters.
    var sourcePhotos: [Photo] {
        switch source {
        case .all:
            photos
        case .lastImport:
            inSortOrder((catalog.lastImport?.refs ?? []).compactMap { photoByRef[$0] })
        case .folder(let id):
            photos.filter { $0.ref.folder == id }
        case .collection(let id):
            inSortOrder((catalog.collections.first { $0.id == id }?.members ?? []).compactMap { photoByRef[$0] })
        }
    }

    /// Collections keep the order photos were added in, unless a sort is chosen.
    private func inSortOrder(_ list: [Photo]) -> [Photo] {
        guard sortOrder != .folder || sortDescending else { return list }
        return list.sorted { (photoPosition[$0.ref] ?? 0) < (photoPosition[$1.ref] ?? 0) }
    }

    /// `list` in the chosen order. Done once per reload or sort change rather than on every
    /// access, so a rating change doesn't make photos jump while culling.
    func sorted(_ list: [Photo]) -> [Photo] {
        // Folder order is the scan order: imported folders in turn, each in Finder's path order.
        // That's what a scan produces already, so keep it rather than re-comparing strings.
        let scanRank = scanOrder
        let folderRank = Dictionary(catalog.folders.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pathKeys = Dictionary(list.map { ($0.url, $0.ref.path) }, uniquingKeysWith: { a, _ in a })
        func pathLess(_ a: Photo, _ b: Photo) -> Bool {
            let fa = folderRank[a.ref.folder] ?? 0, fb = folderRank[b.ref.folder] ?? 0
            if fa != fb { return fa < fb }
            if sortOrder == .folder, let ra = scanRank[a.url], let rb = scanRank[b.url] { return ra < rb }
            return pathKeys[a.url]!.localizedStandardCompare(pathKeys[b.url]!) == .orderedAscending
        }
        var out: [Photo]
        switch sortOrder {
        case .folder:
            out = list.sorted(by: pathLess)
        case .fileName:
            let keys = Dictionary(list.map { ($0.url, $0.name.lowercased()) }, uniquingKeysWith: { a, _ in a })
            out = list.sorted { a, b in
                let ka = keys[a.url]!, kb = keys[b.url]!
                if ka != kb { return ka.compare(kb, options: [.numeric]) == .orderedAscending }
                return pathLess(a, b)
            }
        case .captureTime:
            let dates = catalog.captureDates
            out = list.sorted { a, b in
                let da = dates[a.ref.key] ?? .distantFuture, db = dates[b.ref.key] ?? .distantFuture
                return da != db ? da < db : pathLess(a, b)
            }
        case .rating:
            // Best first reads naturally; descending flips to worst first.
            out = list.sorted { a, b in a.rating != b.rating ? a.rating > b.rating : pathLess(a, b) }
        }
        return sortDescending ? out.reversed() : out
    }

    private func resort() {
        let next = sorted(photos)
        if next.map(\.url) != photos.map(\.url) { photos = next }
    }

    var visiblePhotos: [Photo] {
        sourcePhotos.filter { p in
            if p.rating < minRating { return false }
            if hideRejected && p.flag == .reject && filter != .rejected { return false }
            switch editsFilter {
            case .any: break
            case .edited: if p.adjustments.isDefault { return false }
            case .unedited: if !p.adjustments.isDefault { return false }
            }
            switch filter {
            case .all: return true
            case .picks: return p.flag == .pick
            case .unflagged: return p.flag == .none
            case .rejected: return p.flag == .reject
            }
        }
    }

    var sourceTitle: String {
        switch source {
        case .all: "All photos"
        case .lastImport: "Last import"
        case .folder(let id): catalog.folder(id)?.name ?? "Folder"
        case .collection(let id): catalog.collections.first { $0.id == id }?.name ?? "Collection"
        }
    }

    func count(_ source: LibrarySource) -> Int {
        switch source {
        case .all: photos.count
        case .lastImport: (catalog.lastImport?.refs ?? []).filter { photoByRef[$0] != nil }.count
        case .folder(let id): photos.filter { $0.ref.folder == id }.count
        case .collection(let id): (catalog.collections.first { $0.id == id }?.members ?? []).filter { photoByRef[$0] != nil }.count
        }
    }

    var current: Photo? {
        guard let currentID else { return nil }
        return photoByURL[currentID]
    }

    /// Photos an action like "apply preset" should hit: the selection in the grid, the current photo in the editor.
    var targets: [Photo] {
        if mode == .library && selection.count > 1 {
            return photos.filter { selection.contains($0.url) }
        }
        return current.map { [$0] } ?? []
    }

    /// Selection in the grid (or the current photo).
    var selectedPhotos: [Photo] {
        if mode == .library && !selection.isEmpty {
            return visiblePhotos.filter { selection.contains($0.url) }
        }
        return current.map { [$0] } ?? []
    }

    // MARK: - Loading

    func showImportSheet(prefill: URL? = nil) {
        importPrefill = prefill
        showImport = true
    }

    @ObservationIgnored private var changedPaths: [String] = []

    private func scheduleReload(changed paths: [String] = []) {
        changedPaths += paths
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            let changed = self.changedPaths
            self.changedPaths = []
            self.reload(only: self.foldersContaining(changed))
        }
    }

    /// The imported folders the changed paths are in; nil (rescan everything) when a path is outside
    /// all of them or folders overlap (then which folder owns a file depends on the others).
    func foldersContaining(_ paths: [String]) -> Set<UUID>? {
        guard !paths.isEmpty else { return nil }
        let folders = catalog.folders
        for a in folders {
            for b in folders where a.id != b.id && (b.path + "/").hasPrefix(a.path + "/") { return nil }
        }
        var ids = Set<UUID>()
        for raw in paths {
            let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            guard let f = folders.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else { return nil }
            ids.insert(f.id)
        }
        return ids
    }

    /// Rescans the imported folders (only `only`, when given). Keeps existing Photo objects
    /// (and their unsaved state) for files still present.
    func reload(only: Set<UUID>? = nil, completion: (() -> Void)? = nil) {
        let catalog = self.catalog
        let existing = Dictionary(photos.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(existing.keys)
        let previousOrder = scanOrder
        if photos.isEmpty { isLoading = true }
        if only == nil { watcher?.watch(catalog.folders.filter(\.exists).map(\.path)) }
        Task.detached(priority: .userInitiated) {
            let found = LibraryStore.scanCatalog(catalog, known: known, only: only)
            await MainActor.run {
                var scanned: [UUID: [Photo]] = [:]
                for item in found {
                    let p: Photo
                    if let kept = existing[item.url].flatMap({ $0.ref == item.ref ? $0 : nil }) {
                        p = kept
                    } else {
                        p = Photo(url: item.url, ref: item.ref, sidecar: item.sidecar ?? Sidecar())
                        self.sync.record(item.url, revision: item.revision, base: p.sidecar)
                    }
                    scanned[item.ref.folder, default: []].append(p)
                }
                // Folders in catalog order; untouched ones keep the photos (and order) they had.
                var list: [Photo] = []
                for folder in catalog.folders {
                    if only == nil || only!.contains(folder.id) {
                        list += scanned[folder.id] ?? []
                    } else {
                        list += self.photos.filter { $0.ref.folder == folder.id }
                            .sorted { (previousOrder[$0.url] ?? .max) < (previousOrder[$1.url] ?? .max) }
                    }
                }
                self.scanOrder = Dictionary(list.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { a, _ in a })
                self.photos = self.sorted(list)
                self.sync.keep(only: Set(list.map(\.url)))
                self.isLoading = false
                self.keepCurrentVisible()
                self.backfillFingerprints()
                self.rebuildStyleModel()
                completion?()
            }
        }
    }

    struct ScannedPhoto: Sendable {
        let url: URL
        let ref: PhotoRef
        let sidecar: Sidecar?
        let revision: SidecarRevision
    }

    nonisolated static func scanCatalog(_ catalog: Catalog, known: Set<URL>, only: Set<UUID>? = nil) -> [ScannedPhoto] {
        var seen = Set<String>()
        var entries: [(url: URL, ref: PhotoRef)] = []
        for folder in catalog.folders where folder.exists && (only?.contains(folder.id) ?? true) {
            LibraryFiles.recoverInterruptedRenames(in: folder.url, recursive: folder.includeSubfolders)
            for rel in LibraryFiles.enumerate(folder.url, recursive: folder.includeSubfolders) where !folder.excluded.contains(rel) {
                let url = URL(fileURLWithPath: folder.path).appendingPathComponent(rel)
                guard seen.insert(url.path).inserted else { continue }
                entries.append((url, PhotoRef(folder: folder.id, path: rel)))
            }
        }
        // Sidecars for photos not loaded yet, read in parallel (JSON decoding dominates a first scan).
        let need = entries.indices.filter { !known.contains(entries[$0].url) }
        let box = SidecarBox(count: entries.count)
        DispatchQueue.concurrentPerform(iterations: need.count) { k in
            let i = need[k]
            let url = entries[i].url
            // Under the folder's lock, so a write by the `halfstop` command is never half read.
            let loaded = (try? SidecarLock.with(url, exclusive: false, create: false) { SidecarFiles.load(for: url) })
                ?? SidecarFiles.load(for: url)
            box.set(i, loaded)
        }
        return entries.indices.map {
            let loaded = box.get($0)
            return ScannedPhoto(url: entries[$0].url, ref: entries[$0].ref, sidecar: loaded.sidecar, revision: loaded.revision)
        }
    }

    private final class SidecarBox: @unchecked Sendable {
        private var items: [(sidecar: Sidecar?, revision: SidecarRevision)]
        private let lock = NSLock()
        init(count: Int) { items = Array(repeating: (nil, .none), count: count) }
        func set(_ i: Int, _ s: (sidecar: Sidecar?, revision: SidecarRevision)) { lock.lock(); items[i] = s; lock.unlock() }
        func get(_ i: Int) -> (sidecar: Sidecar?, revision: SidecarRevision) { lock.lock(); defer { lock.unlock() }; return items[i] }
    }

    nonisolated static func sidecarURL(for photo: URL) -> URL { SidecarFiles.mainURL(for: photo) }

    /// Computes fingerprints (duplicate detection) and capture dates (sorting) for library photos
    /// that don't have them yet, in the background.
    @ObservationIgnored private var fingerprinting = false
    private func backfillFingerprints() {
        guard !fingerprinting else { return }
        let needPrint = photos.filter { catalog.fingerprints[$0.ref.key] == nil }.map { ($0.ref.key, $0.url) }
        let needDate = photos.filter { catalog.captureDates[$0.ref.key] == nil }.map { ($0.ref.key, $0.url) }
        guard !needPrint.isEmpty || !needDate.isEmpty else { return }
        fingerprinting = true
        Task.detached(priority: .utility) {
            var prints: [String: String] = [:], dates: [String: Date] = [:]
            for (key, url) in needPrint {
                if let fp = LibraryFiles.fingerprint(url) { prints[key] = fp }
            }
            for (key, url) in needDate { dates[key] = LibraryFiles.captureDate(url) }
            let (p, d) = (prints, dates)
            await MainActor.run {
                self.catalog.fingerprints.merge(p) { _, new in new }
                self.catalog.captureDates.merge(d) { _, new in new }
                self.saveCatalog()
                self.fingerprinting = false
                if self.sortOrder == .captureTime && !d.isEmpty { self.resort() }
            }
        }
    }

    // MARK: - Folders

    func removeFolder(_ id: UUID) {
        flushSaves()
        if let path = catalog.folder(id)?.path {
            forgetFailedSaves { LibraryFiles.isInside($0, LibraryFiles.canonical(URL(fileURLWithPath: path))) || $0.path.hasPrefix(path + "/") }
        }
        catalog.folders.removeAll { $0.id == id }
        for i in catalog.collections.indices {
            catalog.collections[i].members.removeAll { $0.folder == id }
        }
        catalog.fingerprints = catalog.fingerprints.filter { !$0.key.hasPrefix(id.uuidString + "/") }
        catalog.styleSamples = catalog.styleSamples.filter { !$0.key.hasPrefix(id.uuidString + "/") }
        if catalog.lastImport?.folder == id { catalog.lastImport = nil }
        if source == .folder(id) || (source == .lastImport && catalog.lastImport == nil) { source = .all }
        saveCatalog()
        reload()
    }

    /// Points a moved or renamed folder at its new location; edits and collections carry over.
    func relocateFolder(_ id: UUID) {
        guard let i = catalog.folders.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use folder"
        panel.message = "Where is “\(catalog.folders[i].name)” now?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relocateFolder(id, to: url)
    }

    func relocateFolder(_ id: UUID, to url: URL) {
        guard let i = catalog.folders.firstIndex(where: { $0.id == id }) else { return }
        flushSaves()
        catalog.folders[i].path = LibraryFiles.canonical(url)
        saveCatalog()
        photos = photos.filter { $0.ref.folder != id }
        reload()
    }

    // MARK: - Collections

    @discardableResult
    func createCollection(named name: String, with members: [Photo] = []) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let c = PhotoCollection(name: trimmed, members: members.map(\.ref))
        catalog.collections.append(c)
        catalog.targetCollection = c.id
        saveCatalog()
        return c.id
    }

    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = catalog.collections.firstIndex(where: { $0.id == id }) else { return }
        catalog.collections[i].name = trimmed
        saveCatalog()
    }

    func deleteCollection(_ id: UUID) {
        catalog.collections.removeAll { $0.id == id }
        if catalog.targetCollection == id { catalog.targetCollection = catalog.collections.first?.id }
        if source == .collection(id) { source = .all }
        saveCatalog()
    }

    func addToCollection(_ id: UUID, _ items: [Photo]) {
        guard let i = catalog.collections.firstIndex(where: { $0.id == id }) else { return }
        var members = catalog.collections[i].members
        let existing = Set(members)
        members.append(contentsOf: items.map(\.ref).filter { !existing.contains($0) })
        catalog.collections[i].members = members
        saveCatalog()
    }

    func removeFromCollection(_ id: UUID, _ items: [Photo]) {
        guard let i = catalog.collections.firstIndex(where: { $0.id == id }) else { return }
        let drop = Set(items.map(\.ref))
        catalog.collections[i].members.removeAll { drop.contains($0) }
        saveCatalog()
        keepCurrentVisible()
    }

    var targetCollection: PhotoCollection? {
        guard let id = catalog.targetCollection else { return nil }
        return catalog.collections.first { $0.id == id }
    }

    func setTargetCollection(_ id: UUID) {
        catalog.targetCollection = id
        saveCatalog()
    }

    /// The B key: add the selection to the target collection.
    func addSelectionToTarget() {
        guard let target = targetCollection else { return }
        addToCollection(target.id, selectedPhotos)
    }

    /// Drag and drop: dropping one photo of a multi-selection adds the whole selection.
    func dropOnCollection(_ id: UUID, urls: [URL]) {
        var items = urls.compactMap { photoByURL[$0] }
        if items.contains(where: { selection.contains($0.url) }) {
            items = photos.filter { selection.contains($0.url) }
        }
        addToCollection(id, items)
    }

    // MARK: - Persistence

    /// - Parameter history: the edit history changed too, so write its file (it's skipped otherwise).
    ///   Sticks until a save goes through, so a later rating or slider save still includes it.
    func scheduleSave(_ photo: Photo, history: Bool = false) {
        if history { historyDirty.insert(photo.url) }
        scheduleWrite(photo.url, sidecar: photo.sidecar, delay: 0.5)
    }

    private func scheduleWrite(_ url: URL, sidecar: Sidecar, delay: Double) {
        pendingSaves[url]?.cancel()
        let withHistory = historyDirty.contains(url)
        let token = UUID()
        let sync = self.sync, epoch = sync.epoch(url)
        let work = DispatchWorkItem { [weak self] in
            let outcome = sync.save(sidecar, for: url, history: withHistory, epoch: epoch)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.didWrite(url, token: token, sidecar: sidecar, outcome: outcome) }
            }
        }
        pendingSaves[url] = work
        pendingTokens[url] = token
        unsavedCount = pendingSaves.count
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func didWrite(_ url: URL, token: UUID, sidecar: Sidecar, outcome: SidecarSync.SaveOutcome) {
        if case .changedOnDisk(let change) = outcome {
            if pendingTokens[url] == token {
                pendingTokens[url] = nil
                pendingSaves[url] = nil
                unsavedCount = pendingSaves.count
            }
            // Saved again, merged, if the app had changes of its own.
            takeExternalChange(change)
            return
        }
        guard pendingTokens[url] == token else { return }
        pendingTokens[url] = nil
        pendingSaves[url] = nil
        switch outcome {
        case .saved: recordSave(url, sidecar: sidecar, failure: nil)
        case .failed(let error): recordSave(url, sidecar: sidecar, failure: Self.describeSaveError(error))
        case .superseded, .changedOnDisk: break
        }
        unsavedCount = pendingSaves.count
    }

    /// Notes how a save went. A failure keeps the history marked dirty, so the retry writes it.
    private func recordSave(_ url: URL, sidecar: Sidecar, failure: String?) {
        if let failure {
            failedSaves[url] = failure
            failedSnapshots[url] = (sidecar, historyDirty.contains(url) || failedSnapshots[url]?.history == true)
        } else {
            historyDirty.remove(url)
            failedSaves[url] = nil
            failedSnapshots[url] = nil
            lastSaved = Date()
        }
        updateRetryTimer()
    }

    /// Stops retrying saves for these photos (trashed, or their folder left the library).
    private func forgetFailedSaves(where drop: (URL) -> Bool) {
        for url in failedSaves.keys where drop(url) {
            failedSaves[url] = nil
            failedSnapshots[url] = nil
        }
        updateRetryTimer()
    }

    /// Writes every pending and failed save now, on this thread. Failures stay recorded.
    func flushSaves() {
        commitAllPending()
        let urls = Set(pendingSaves.keys).union(failedSaves.keys)
        for (_, work) in pendingSaves { work.cancel() }
        pendingSaves = [:]
        pendingTokens = [:]
        for url in urls {
            // A change on disk found while saving is merged in, then saved (a few rounds at most).
            attempts: for _ in 0..<3 {
                guard let sidecar = photoByURL[url]?.sidecar ?? failedSnapshots[url]?.sidecar else { break }
                if failedSnapshots[url]?.history == true { historyDirty.insert(url) }
                switch sync.save(sidecar, for: url, history: historyDirty.contains(url), epoch: sync.epoch(url)) {
                case .saved:
                    recordSave(url, sidecar: sidecar, failure: nil)
                    break attempts
                case .failed(let error):
                    recordSave(url, sidecar: sidecar, failure: Self.describeSaveError(error))
                    break attempts
                case .changedOnDisk(let change):
                    guard takeExternalChange(change, scheduleSave: false) else { break attempts }
                    historyDirty.insert(url)
                case .superseded:
                    continue
                }
            }
        }
        for (_, work) in pendingSaves { work.cancel() }
        pendingSaves = [:]
        pendingTokens = [:]
        unsavedCount = 0
        if let pending = pendingCatalogSave {
            // Learned samples waiting to be written.
            pending.cancel()
            pendingCatalogSave = nil
            saveCatalog()
        }
        updateRetryTimer()
    }

    /// ⌘S: everything is saved automatically, but this writes it out right now and says so.
    /// If anything can't be saved, shows why instead.
    func saveNow() {
        flushSaves()
        saveCatalog()
        if failedLibraryFiles["Presets"] != nil { savePresets() }
        guard !hasSaveProblems else {
            showSaveProblems = true
            return
        }
        lastSaved = Date()
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.savedFlash = false }
    }

    /// "Try again" in the save problems popover, and the 30 s timer.
    func retryFailedSaves() {
        for url in failedSaves.keys where pendingSaves[url] == nil {
            guard let sidecar = photoByURL[url]?.sidecar ?? failedSnapshots[url]?.sidecar else { continue }
            if failedSnapshots[url]?.history == true { historyDirty.insert(url) }
            scheduleWrite(url, sidecar: sidecar, delay: 0)
        }
        if failedLibraryFiles["Library index"] != nil { saveCatalog() }
        if failedLibraryFiles["Presets"] != nil { savePresets() }
        updateRetryTimer()
    }

    var hasSaveProblems: Bool { !failedSaves.isEmpty || !failedLibraryFiles.isEmpty }

    /// One line per place that can't be saved: photos grouped by imported folder, then library files.
    var saveProblems: [SaveProblem] {
        var groups: [String: (folder: URL?, reason: String, count: Int)] = [:]
        for (url, reason) in failedSaves {
            let name = photoByURL[url].flatMap { catalog.folder($0.ref.folder)?.name } ?? url.deletingLastPathComponent().lastPathComponent
            let folder = photoByURL[url].flatMap { catalog.folder($0.ref.folder)?.url } ?? url.deletingLastPathComponent()
            var g = groups[name] ?? (folder, reason, 0)
            g.count += 1
            groups[name] = g
        }
        var out = groups.map { SaveProblem(title: $0.key, photoCount: $0.value.count, reason: $0.value.reason, folder: $0.value.folder) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        for (name, reason) in failedLibraryFiles.sorted(by: { $0.key < $1.key }) {
            out.append(SaveProblem(title: name, photoCount: 0, reason: reason, folder: nil))
        }
        return out
    }

    private func updateRetryTimer() {
        if hasSaveProblems {
            guard retryTimer == nil else { return }
            retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryFailedSaves() }
            }
        } else {
            retryTimer?.invalidate()
            retryTimer = nil
            showSaveProblems = false
        }
    }

    /// Writes the sidecar of a photo that isn't loaded yet (presets at import), holding the folder's
    /// sidecar lock; returns why it couldn't be, or nil when it was saved.
    @discardableResult
    nonisolated static func writeSidecar(_ sidecar: Sidecar, for url: URL, history: Bool) -> String? {
        do {
            try SidecarLock.with(url, exclusive: true, create: !sidecar.isEmpty) {
                _ = try SidecarFiles.write(sidecar, for: url, history: history)
            }
            return nil
        } catch {
            return describeSaveError(error)
        }
    }

    /// A short, plain reason for a failed save.
    nonisolated static func describeSaveError(_ error: Error) -> String {
        if error is SidecarFiles.Failure { return "The edits folder is a link, so it isn’t used" }
        if error is SidecarLock.Failure { return "Another program kept the edits locked; trying again" }
        let ns = error as NSError
        var posix: Int32?
        if ns.domain == NSPOSIXErrorDomain { posix = Int32(ns.code) }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain { posix = Int32(under.code) }
        switch posix {
        case EROFS: return "The disk is read-only"
        case ENOSPC, EDQUOT: return "The disk is full"
        case EACCES, EPERM: return "The folder is read-only (locked card?)"
        case ENOENT, ENXIO, ENODEV: return "The folder isn’t available (disconnected?)"
        default: break
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteVolumeReadOnlyError: return "The disk is read-only"
            case NSFileWriteOutOfSpaceError: return "The disk is full"
            case NSFileWriteNoPermissionError: return "The folder is read-only (locked card?)"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "The folder isn’t available (disconnected?)"
            default: break
            }
        }
        return ns.localizedDescription
    }

    // MARK: - Navigation & selection

    func select(_ photo: Photo, extend: Bool = false, toggle: Bool = false) {
        if toggle {
            if selection.contains(photo.url) { selection.remove(photo.url) } else { selection.insert(photo.url) }
            selectionAnchor = photo.url
        } else if extend, let anchor = selectionAnchor ?? currentID {
            let list = visiblePhotos
            if let a = list.firstIndex(where: { $0.url == anchor }), let b = list.firstIndex(of: photo) {
                selection = Set(list[min(a, b)...max(a, b)].map(\.url))
            }
        } else {
            selection = [photo.url]
            selectionAnchor = photo.url
        }
        setCurrent(photo.url)
    }

    func open(_ photo: Photo) {
        select(photo)
        mode = .edit
    }

    /// Which way the last step went (+1 / -1), so the editor preloads ahead of you.
    @ObservationIgnored private(set) var browseDirection = 1

    func step(_ delta: Int) {
        let list = visiblePhotos
        guard !list.isEmpty else { return }
        if delta != 0 { browseDirection = delta > 0 ? 1 : -1 }
        let index = list.firstIndex { $0.url == currentID } ?? 0
        let next = list[min(max(index + delta, 0), list.count - 1)]
        select(next)
    }

    func stepRow(_ delta: Int, columns: Int) { step(delta * max(columns, 1)) }

    private func setCurrent(_ url: URL?) {
        if currentID != url {
            if let previous = current { commitPending(previous) }
            isCropping = false; showBefore = false; activeMaskID = nil
        }
        currentID = url
    }

    private func keepCurrentVisible() {
        let list = visiblePhotos
        if let currentID, list.contains(where: { $0.url == currentID }) { return }
        setCurrent(list.first?.url)
        selection = currentID.map { [$0] } ?? []
    }

    // MARK: - Trash

    /// How a file goes to the Trash. Tests swap this for a scratch folder so they never touch the real Trash.
    nonisolated(unsafe) static var trashFile: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Asks for confirmation (see `TrashConfirmation`) before moving these photos' files to the Trash.
    func requestTrash(_ items: [Photo]) {
        guard !items.isEmpty else { return }
        trashRequest = TrashRequest(urls: items.map(\.url), rejectedOnly: false)
    }

    /// Every rejected photo in the current source (ignores filters, so hidden rejects count too).
    var rejectedInSource: [Photo] { sourcePhotos.filter { $0.flag == .reject } }

    func requestTrashRejected() {
        let items = rejectedInSource
        guard !items.isEmpty else { return }
        trashRequest = TrashRequest(urls: items.map(\.url), rejectedOnly: true)
    }

    /// Moves the photo files (and their `.halfstop` sidecars) to the Trash, where Finder can put them back,
    /// and drops them from the library, collections and last import. Returns the files that couldn't be moved.
    @discardableResult
    func moveToTrash(_ urls: [URL]) -> [String] {
        let wanted = Set(urls)
        let items = photos.filter { wanted.contains($0.url) }
        guard !items.isEmpty else { return [] }

        // Remember where we were so the next photo takes the current one's place.
        let before = visiblePhotos
        let currentIndex = before.firstIndex { $0.url == currentID }

        var moved: [Photo] = []
        var failed: [String] = []
        let fm = FileManager.default
        for p in items {
            // Don't let a pending save or history step recreate the sidecar afterwards.
            pendingSaves[p.url]?.cancel(); pendingSaves[p.url] = nil; pendingTokens[p.url] = nil; historyDirty.remove(p.url)
            pendingCommits[p.url]?.cancel(); pendingCommits[p.url] = nil
            sync.forget(p.url)
            do {
                try Self.trashFile(p.url)
                for sidecar in SidecarFiles.all(for: p.url) where fm.fileExists(atPath: sidecar.path) && SidecarFiles.isSafe(sidecar, for: p.url) {
                    try? Self.trashFile(sidecar)
                }
                moved.append(p)
            } catch {
                failed.append(p.url.lastPathComponent)
            }
        }
        unsavedCount = pendingSaves.count
        guard !moved.isEmpty else { return failed }
        let trashed = Set(moved.map(\.url))
        forgetFailedSaves { trashed.contains($0) }

        catalog.forget(Set(moved.map(\.ref)))
        saveCatalog()
        for p in moved { styleModel.remove(p.ref.key) }
        updateStyleActive()
        let gone = Set(moved.map(\.url))
        photos.removeAll { gone.contains($0.url) }
        selection.subtract(gone)

        if let id = currentID, gone.contains(id) {
            currentID = nil
            let after = visiblePhotos
            if let i = currentIndex, !after.isEmpty {
                // Next surviving photo after the old position, else the one before it.
                let next = before[i...].first { !gone.contains($0.url) } ?? before[..<i].last { !gone.contains($0.url) }
                setCurrent(next?.url ?? after[min(i, after.count - 1)].url)
            } else {
                setCurrent(after.first?.url)
            }
            selection = currentID.map { [$0] } ?? []
        }
        if photos.isEmpty || currentID == nil { mode = .library }
        return failed
    }

    // MARK: - Culling

    func setRating(_ rating: Int) {
        let targets = self.targets
        for p in targets { p.rating = (targets.count == 1 && p.rating == rating) ? 0 : rating; scheduleSave(p) }
    }

    func setFlag(_ flag: Flag) {
        for p in targets { p.flag = flag; scheduleSave(p) }
    }

    // MARK: - Editing & history

    nonisolated static let historyLimit = 100
    /// Pause after the last change before it becomes a history step (one slider drag = one step).
    static let historySettle: TimeInterval = 0.6

    /// Call when a new gesture starts (slider grab, handle drag…): closes off the previous
    /// change as its own history step so two gestures never merge.
    func checkpoint() {
        if let photo = current { commitPending(photo) }
    }

    func edit(_ change: (inout Adjustments) -> Void) {
        guard let photo = current else { return }
        var a = photo.adjustments
        change(&a)
        guard a != photo.adjustments else { return }
        photo.adjustments = a
        scheduleSave(photo)
        scheduleCommit(photo)
    }

    /// Binding-friendly accessor for a single slider value.
    func value(_ keyPath: WritableKeyPath<Adjustments, Double>) -> Double {
        current?.adjustments[keyPath: keyPath] ?? 0
    }

    func set(_ keyPath: WritableKeyPath<Adjustments, Double>, _ value: Double) {
        edit { $0[keyPath: keyPath] = value }
    }

    private func scheduleCommit(_ photo: Photo) {
        pendingCommits[photo.url]?.cancel()
        let work = DispatchWorkItem { [weak self, weak photo] in
            guard let self, let photo else { return }
            MainActor.assumeIsolated { self.commitPending(photo) }
        }
        pendingCommits[photo.url] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.historySettle, execute: work)
    }

    /// Turns any not-yet-recorded change into a history step now.
    func commitPending(_ photo: Photo) {
        pendingCommits[photo.url]?.cancel()
        pendingCommits[photo.url] = nil
        recordStep(photo)
    }

    func commitAllPending() {
        for p in photos where pendingCommits[p.url] != nil { commitPending(p) }
    }

    /// Adds a step for the photo's current state if it differs from the current step.
    /// Steps after the current one (struck out in the panel) are trimmed: this is where you "cull down".
    func recordStep(_ photo: Photo, label: String? = nil) {
        let index = min(photo.historyIndex, photo.history.count - 1)
        let previous = photo.history.indices.contains(index) ? photo.history[index].adjustments : Adjustments()
        guard photo.adjustments != previous else { return }
        var history = Array(photo.history.prefix(index + 1))
        history.append(HistoryStep(label: label ?? HistoryLabel.describe(from: previous, to: photo.adjustments),
                                   adjustments: photo.adjustments))
        if history.count > Self.historyLimit {
            // Keep the first step (the original) and the most recent ones.
            history = [history[0]] + history.suffix(Self.historyLimit - 1)
        }
        photo.history = history
        photo.historyIndex = history.count - 1
        scheduleSave(photo, history: true)
        noteEdited(photo)
    }

    /// Sets a photo's edits as one labelled step (paste, presets, snapshots, reset).
    // MARK: - Auto adjustments

    /// White balance that makes the clicked spot neutral gray (`p` normalized in the cropped photo).
    func pickWhiteBalance(at p: NormPoint) {
        pickingWhite = false
        let half = 0.008
        runAuto(.pickedWhite(NormRect(x: p.x - half, y: p.y - half, width: half * 2, height: half * 2)))
    }

    /// Measures in the background, then applies the result as one history step, unless the user
    /// moved to another photo or changed the edits meanwhile (then the result is dropped).
    /// The returned task says whether it was applied.
    @discardableResult
    func runAuto(_ kind: AutoKind) -> Task<Bool, Never>? {
        guard let task = performAuto(kind) else { return nil }
        return Task { await task.value == .applied }
    }

    /// `runAuto` with the full outcome (for callers that report it, like a tool layer).
    func performAuto(_ kind: AutoKind) -> Task<AutoOutcome, Never>? {
        guard let photo = current, !isAutoRunning else { return nil }
        commitPending(photo)
        let start = photo.adjustments
        let request = AutoRequest(url: photo.url, kind: kind, adjustments: start)
        let run = AutoRun(url: photo.url, kind: kind, id: UUID())
        autoRun = run
        return Task { [weak self] in
            let result = await AutoEngine.shared.result(for: request)
            guard let self else { return .stale }
            if self.autoRun == run { self.autoRun = nil }
            return self.finishAuto(request, start: start, result: result)
        }
    }

    /// True while an auto action runs for the photo being edited (its row is disabled).
    var isAutoRunning: Bool { autoRun != nil && autoRun?.url == currentID }

    /// Applies a finished measurement if the photo and its edits are still what it measured.
    @discardableResult
    func finishAuto(_ request: AutoRequest, start: Adjustments, result: AutoResult?) -> AutoOutcome {
        guard let photo = current, photo.url == request.url, photo.adjustments == start else { return .stale }
        guard var result else { return .unreadable }
        if request.kind == .straighten {
            guard result.angle != nil else {
                showHint("No horizon found")
                return .noHorizon
            }
        }
        if request.kind == .auto { result.learned = learnedOffset(for: photo, result: result) }
        let next = result.applied(to: start)
        guard next != start else {
            if request.kind == .straighten { showHint("Horizon already level") }
            return .unchanged
        }
        applyStep(photo, next, label: request.kind.label)
        return .applied
    }

    /// A short message over the photo (where the editor shows its hints), gone after a moment.
    private(set) var hint: String?
    @ObservationIgnored private var hintTimer: DispatchWorkItem?

    func showHint(_ text: String) {
        hintTimer?.cancel()
        hint = text
        let work = DispatchWorkItem { [weak self] in self?.hint = nil }
        hintTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func applyStep(_ photo: Photo, _ adjustments: Adjustments, label: String) {
        commitPending(photo)
        photo.adjustments = adjustments
        recordStep(photo, label: label)
        scheduleSave(photo)
    }

    /// Jump to a history step. Later steps stay visible (and redoable) until the next edit.
    func jumpToStep(_ index: Int) {
        guard let photo = current else { return }
        commitPending(photo)
        guard photo.history.indices.contains(index) else { return }
        photo.historyIndex = index
        photo.adjustments = photo.history[index].adjustments
        scheduleSave(photo, history: true)
        noteEdited(photo)
    }

    /// Drops the steps after the current one right away.
    func trimHistoryAfterCurrent() {
        guard let photo = current else { return }
        commitPending(photo)
        photo.history = Array(photo.history.prefix(photo.historyIndex + 1))
        scheduleSave(photo, history: true)
    }

    /// Forgets the history, keeping the current edits as the new starting point.
    func clearHistory() {
        guard let photo = current else { return }
        commitPending(photo)
        photo.history = [HistoryStep(label: "History cleared", adjustments: photo.adjustments)]
        photo.historyIndex = 0
        scheduleSave(photo, history: true)
    }

    var canUndo: Bool {
        guard let p = current else { return false }
        return p.historyIndex > 0 || pendingCommits[p.url] != nil
    }
    var canRedo: Bool {
        guard let p = current else { return false }
        return p.historyIndex < p.history.count - 1
    }

    func undo() {
        guard let photo = current else { return }
        commitPending(photo)
        guard photo.historyIndex > 0 else { return }
        jumpToStep(photo.historyIndex - 1)
    }

    func redo() {
        guard let photo = current, canRedo else { return }
        jumpToStep(photo.historyIndex + 1)
    }

    // MARK: Snapshots

    func saveSnapshot(named name: String) {
        guard let photo = current else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        commitPending(photo)
        photo.snapshots.append(EditSnapshot(name: trimmed, adjustments: photo.adjustments))
        scheduleSave(photo)
    }

    func applySnapshot(_ snapshot: EditSnapshot) {
        guard let photo = current else { return }
        applyStep(photo, snapshot.adjustments, label: "Snapshot: \(snapshot.name)")
    }

    func renameSnapshot(_ id: UUID, to name: String) {
        guard let photo = current, let i = photo.snapshots.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        photo.snapshots[i].name = trimmed
        scheduleSave(photo)
    }

    func deleteSnapshot(_ id: UUID) {
        guard let photo = current else { return }
        photo.snapshots.removeAll { $0.id == id }
        scheduleSave(photo)
    }

    func resetAdjustments() {
        for p in targets { applyStep(p, Adjustments(), label: "Reset all") }
    }

    func resetSection(_ apply: (inout Adjustments) -> Void) {
        checkpoint()
        edit { a in apply(&a) }
    }

    // MARK: - Masks

    var activeMask: Mask? {
        guard let id = activeMaskID else { return nil }
        return current?.adjustments.masks.first { $0.id == id }
    }

    func addMask(_ kind: MaskKind) {
        guard let photo = current else { return }
        checkpoint()
        let count = photo.adjustments.masks.filter { $0.kind == kind }.count
        var mask = Mask(name: kind.isAutomatic && count == 0 ? kind.label : "\(kind.label) \(count + 1)", kind: kind)
        if kind == .sky { mask.name = count == 0 ? "Sky" : "Sky \(count + 1)" }
        edit { $0.masks.append(mask) }
        mask = photo.adjustments.masks.last ?? mask
        panelTab = .detailed
        activeMaskID = mask.id
        flashOverlay()
    }

    /// Click on the photo with a subject mask: include or exclude the subject under the pointer.
    func toggleSubject(at p: NormPoint) {
        guard let mask = activeMask, mask.kind == .subject, let url = currentID,
              let count = SubjectDetector.shared.subjectCount(url), count > 0,
              let hit = SubjectDetector.shared.subject(at: p, url: url) else { return }
        setSubject(hit, included: !(mask.subjects ?? Array(1...count)).contains(hit), count: count)
    }

    func setSubject(_ n: Int, included: Bool, count: Int) {
        guard let mask = activeMask else { return }
        var set = Set(mask.subjects ?? Array(1...count))
        if included { set.insert(n) } else { set.remove(n) }
        checkpoint()
        editMask { $0.subjects = set.count == count ? nil : set.sorted() }
    }

    /// Adds a linear or radial shape to the active mask and selects it.
    @discardableResult
    func addShape(_ kind: ShapeKind, mode: CombineMode = .add, configure: ((inout MaskShape) -> Void)? = nil) -> UUID? {
        guard activeMask != nil else { return nil }
        var shape = MaskShape(kind: kind, mode: mode)
        if kind == .linear {
            shape.start = NormPoint(x: 0.5, y: 0.85)
            shape.end = NormPoint(x: 0.5, y: 0.55)
        } else {
            shape.radiusX = 0.18; shape.radiusY = 0.18
        }
        configure?(&shape)
        checkpoint()
        editMask { $0.shapes.append(shape) }
        activeShapeID = shape.id
        refineMode = nil
        return shape.id
    }

    func deleteShape(_ id: UUID) {
        checkpoint()
        editMask { $0.shapes.removeAll { $0.id == id } }
        if activeShapeID == id { activeShapeID = nil }
    }

    func setShapeMode(_ id: UUID, _ mode: CombineMode) {
        checkpoint()
        editMask { m in
            if let i = m.shapes.firstIndex(where: { $0.id == id }) { m.shapes[i].mode = mode }
        }
    }

    func deleteMask(_ id: UUID) {
        checkpoint()
        edit { $0.masks.removeAll { $0.id == id } }
        if activeMaskID == id { activeMaskID = nil }
    }

    func editMask(_ id: UUID? = nil, _ change: (inout Mask) -> Void) {
        guard let id = id ?? activeMaskID else { return }
        edit { a in
            guard let i = a.masks.firstIndex(where: { $0.id == id }) else { return }
            change(&a.masks[i])
        }
    }

    /// Slider value in the current scope (active mask or whole photo).
    func scopedValue(_ global: WritableKeyPath<Adjustments, Double>, _ local: WritableKeyPath<LocalAdjustments, Double>?) -> Double {
        if let mask = activeMask, let local { return mask.local[keyPath: local] }
        return value(global)
    }

    func setScoped(_ global: WritableKeyPath<Adjustments, Double>, _ local: WritableKeyPath<LocalAdjustments, Double>?, _ v: Double) {
        if activeMaskID != nil, let local {
            editMask { $0.local[keyPath: local] = v }
        } else {
            set(global, v)
        }
    }

    @ObservationIgnored private var overlayFlash: DispatchWorkItem?
    /// User toggle (keyboard / checkbox) — wins over a pending flash.
    func setOverlay(_ on: Bool) {
        overlayFlash?.cancel()
        overlayFlash = nil
        showMaskOverlay = on
    }

    func flashOverlay() {
        overlayFlash?.cancel()
        showMaskOverlay = true
        let work = DispatchWorkItem { [weak self] in self?.showMaskOverlay = false }
        overlayFlash = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    // MARK: - Copy / paste / presets

    func copySettings() {
        clipboard = current?.adjustments
    }

    func pasteSettings() {
        guard let clipboard else { return }
        for p in targets { applyStep(p, clipboard.withCrop(from: p.adjustments), label: "Paste settings") }
    }

    /// Groups ticked in the last selective paste.
    var pasteGroups: Set<SettingsGroup> = {
        let saved = (UserDefaults.standard.array(forKey: "pasteGroups") as? [String])?.compactMap(SettingsGroup.init(rawValue:))
        return saved.map(Set.init) ?? SettingsGroup.standard
    }() {
        didSet { UserDefaults.standard.set(pasteGroups.map(\.rawValue), forKey: "pasteGroups") }
    }
    var showSelectivePaste = false

    func pasteSettings(_ groups: Set<SettingsGroup>) {
        guard let clipboard, !groups.isEmpty else { return }
        let label = groups == Set(SettingsGroup.allCases) ? "Paste all settings" : "Paste settings (\(groups.count) of \(SettingsGroup.allCases.count))"
        for p in targets { applyStep(p, p.adjustments.copying(groups, from: clipboard), label: label) }
    }

    func apply(_ preset: Preset) {
        for p in targets { applyStep(p, preset.adjustments.asPreset(onto: p.adjustments), label: "Preset: \(preset.name)") }
    }

    func saveCurrentAsPreset(named name: String) {
        guard let a = current?.adjustments else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var stripped = a
        stripped.crop = CropSettings()
        stripped.masks = []
        if let i = presets.firstIndex(where: { $0.name == trimmed }) {
            presets[i].adjustments = stripped
        } else {
            presets.append(Preset(name: trimmed, adjustments: stripped))
            presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        savePresets()
    }

    func deletePreset(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    private static var presetsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halfstop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    private func loadPresets() {
        presets = Self.loadPresets(from: Self.presetsURL)
    }

    /// Every preset that can be read. If any can't, the file is copied aside first so the next
    /// save doesn't lose them; an unreadable file is copied aside too.
    nonisolated static func loadPresets(from url: URL) -> [Preset] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let report = DecodeReport()
        guard let list = try? JSONDecoder.reporting(into: report).decode(TolerantList<Preset>.self, from: data) else {
            FileBackup.keepPartiallyLoaded(url, data: data)
            return []
        }
        if report.dropped > 0 { FileBackup.keepPartiallyLoaded(url, data: data) }
        return list.items
    }

    private func savePresets() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        do {
            try encoder.encode(presets).write(to: Self.presetsURL, options: .atomic)
            failedLibraryFiles["Presets"] = nil
        } catch {
            failedLibraryFiles["Presets"] = Self.describeSaveError(error)
        }
        updateRetryTimer()
    }
}

/// A place edits can't be saved to, for the save problems popover.
struct SaveProblem: Identifiable, Hashable {
    var id: String { title }
    let title: String
    /// 0 for library files.
    let photoCount: Int
    let reason: String
    let folder: URL?
}

struct TrashRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    /// Came from "Delete Rejected…" (changes the wording).
    let rejectedOnly: Bool
}

// MARK: - Changes made outside the app

extension LibraryStore {
    /// The photo a sidecar file belongs to: `<folder>/.halfstop/<name>.json` or `.history.json`.
    nonisolated static func photoURL(forSidecarPath path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        guard dir.lastPathComponent == SidecarFiles.folderName else { return nil }
        let file = url.lastPathComponent
        let name: String
        if file.hasSuffix(".history.json") {
            name = String(file.dropLast(".history.json".count))
        } else if file.hasSuffix(".json") {
            name = String(file.dropLast(".json".count))
        } else {
            return nil
        }
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        return dir.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// FSEvents saw sidecar files change: look for changes made outside the app, in the background.
    func sidecarsChanged(_ paths: [String]) {
        let urls = Set(paths.compactMap(Self.photoURL(forSidecarPath:)).filter { photoByURL[$0] != nil })
        guard !urls.isEmpty else { return }
        Task { await checkSidecars(urls) }
    }

    /// Reads these photos' sidecars off the main thread and takes in any change made outside the app.
    /// The app's own saves are recognized (same content as it last wrote) and ignored.
    func checkSidecars(_ urls: Set<URL>) async {
        let sync = self.sync
        let changes = await Task.detached(priority: .utility) { urls.sorted { $0.path < $1.path }.compactMap { sync.check($0) } }.value
        for change in changes { takeExternalChange(change) }
    }

    /// Takes in a photo's sidecar as changed on disk by another program. The rule (`SidecarMerge`):
    /// with no unsaved changes in the app, the disk's version replaces the photo's edits, history
    /// included; otherwise the app's changes are applied on top as a new step and saved. Either way
    /// it can be undone in the app. Returns whether the result still has to be saved.
    @discardableResult
    func takeExternalChange(_ change: ExternalSidecarChange, scheduleSave save: Bool = true) -> Bool {
        let url = change.url
        // An older find (a newer one is on its way), or a photo that's gone.
        guard change.epoch == sync.epoch(url), let photo = photoByURL[url], let known = sync.state(url) else { return false }
        commitPending(photo)
        var theirs = change.sidecar
        theirs.ensureHistory()
        let result = SidecarMerge.merge(base: known.base, ours: photo.sidecar, theirs: theirs, historyLimit: Self.historyLimit)
        sync.record(url, revision: change.revision, base: theirs)
        // Saves of the app's older version are void now.
        pendingSaves[url]?.cancel()
        pendingSaves[url] = nil
        pendingTokens[url] = nil
        historyDirty.remove(url)
        photo.adopt(result.sidecar)
        if let id = activeMaskID, photo === current, !photo.adjustments.masks.contains(where: { $0.id == id }) { activeMaskID = nil }
        if result.keptLocalChanges {
            historyDirty.insert(url)
            if save { scheduleWrite(url, sidecar: photo.sidecar, delay: 0) }
        } else {
            failedSaves[url] = nil
            failedSnapshots[url] = nil
        }
        unsavedCount = pendingSaves.count
        updateRetryTimer()
        refreshStyleEntry(photo)
        if photo === current {
            if result.keptLocalChanges {
                showHint("Merged with changes made outside Halfstop")
            } else if theirs.currentStep?.commandLine == true {
                showHint("Updated from the command line: \(theirs.currentStep?.label ?? "")")
            } else {
                showHint("Updated with changes made outside Halfstop")
            }
        }
        return result.keptLocalChanges
    }
}

// MARK: - Learn from my edits

extension LibraryStore {
    /// ✦ Auto's tooltip says it adapts once this is true: learning is on and there are enough
    /// edited photos besides the open one (its own edit never feeds its own prediction).
    var autoIsAdapted: Bool {
        learnFromEdits && styleActive && styleModel.isActive(for: current?.ref.key)
    }

    /// What learning adds to ✦ Auto's result for `photo` (nil when off, with too few edited
    /// photos, or nothing to add). Microseconds: a search over the in-memory index.
    func learnedOffset(for photo: Photo, result: AutoResult) -> StyleOffset? {
        guard learnFromEdits, styleModel.isActive, let f = StyleFeatures.make(result, isRAW: photo.isRAW) else { return nil }
        return styleModel.predict(f, excluding: photo.ref.key)
    }

    /// Rebuilds the index from the catalog's samples and the photos' current edits (after the
    /// library loads, or when learning is switched on). O(library), never per click.
    func rebuildStyleModel() {
        styleModel.removeAll()
        if learnFromEdits {
            // A photo whose current step came from the `halfstop` command isn't an edit by hand.
            for p in photos where !p.atCommandLineStep {
                if let sample = catalog.styleSamples[p.ref.key] { styleModel.update(p.ref.key, sample: sample, adjustments: p.adjustments) }
            }
        }
        updateStyleActive()
    }

    /// After the photo's edits were reloaded from disk: its entry follows them, without measuring.
    func refreshStyleEntry(_ photo: Photo) {
        guard learnFromEdits else { return }
        if photo.atCommandLineStep {
            styleModel.remove(photo.ref.key)
        } else {
            styleModel.update(photo.ref.key, sample: catalog.styleSamples[photo.ref.key], adjustments: photo.adjustments)
        }
        updateStyleActive()
    }

    func updateStyleActive() {
        let active = styleModel.isActive
        if styleActive != active { styleActive = active }
    }

    /// After a history step (or undo/redo): updates the photo's entry, and if it's edited by hand
    /// but has no current sample, measures one in the background shortly after.
    func noteEdited(_ photo: Photo) {
        guard learnFromEdits else { return }
        // Undo or redo onto a step made by the `halfstop` command: not an edit by hand.
        guard !photo.atCommandLineStep else {
            refreshStyleEntry(photo)
            return
        }
        let sample = catalog.styleSamples[photo.ref.key]
        styleModel.update(photo.ref.key, sample: sample, adjustments: photo.adjustments)
        updateStyleActive()
        // Only the photo being edited is measured: pasting or applying a preset to a large
        // selection would otherwise queue one background ✦ Auto per photo ahead of the next click.
        if photo === current, StyleSliders.isEdited(photo.adjustments), sample?.isUsable(crop: photo.adjustments.crop) != true {
            scheduleStyleSample(photo)
        }
    }

    /// How long after an edit its sample is measured (edits come in bursts).
    static let styleSampleDelay: TimeInterval = 1.5

    private func scheduleStyleSample(_ photo: Photo) {
        let url = photo.url
        pendingStyleSamples[url]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { _ = self?.measureStyleSample(url) }
        }
        pendingStyleSamples[url] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.styleSampleDelay, execute: work)
    }

    /// Measures ✦ Auto for the photo (off the main thread, on the shared engine, so a later ✦ Auto
    /// click on it is a cache hit) and stores the sample in the catalog.
    @discardableResult
    func measureStyleSample(_ url: URL) -> Task<Void, Never>? {
        pendingStyleSamples[url] = nil
        guard learnFromEdits, let photo = photo(for: url), StyleSliders.isEdited(photo.adjustments) else { return nil }
        let crop = photo.adjustments.crop, ref = photo.ref, isRAW = photo.isRAW
        let request = AutoRequest(url: url, kind: .auto, adjustments: photo.adjustments)
        return Task { [weak self] in
            guard let result = await AutoEngine.shared.result(for: request),
                  let features = StyleFeatures.make(result, isRAW: isRAW), let self else { return }
            // The photo may have gone or been re-cropped meanwhile.
            guard let photo = self.photo(for: url), photo.ref == ref, photo.adjustments.crop == crop else { return }
            let sample = StyleSample(features: features, auto: StyleSliders.values(result.applied(to: Adjustments())), crop: crop)
            self.catalog.styleSamples[ref.key] = sample
            self.scheduleCatalogSave()
            if self.learnFromEdits, !photo.atCommandLineStep {
                self.styleModel.update(ref.key, sample: sample, adjustments: photo.adjustments)
                self.updateStyleActive()
            }
        }
    }

    func photo(for url: URL) -> Photo? { photoByURL[url] }

    /// Saves the catalog a moment after the last of a burst of changes.
    private func scheduleCatalogSave() {
        pendingCatalogSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingCatalogSave = nil
                self?.saveCatalog()
            }
        }
        pendingCatalogSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

