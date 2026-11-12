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
    /// Move to the next photo after rating or flagging one (⇧ with the key does it once).
    var autoAdvance = UserDefaults.standard.bool(forKey: "autoAdvance") {
        didSet { UserDefaults.standard.set(autoAdvance, forKey: "autoAdvance") }
    }
    var thumbnailSize: Double = 200
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
            watcher = FolderWatcher { [weak self] paths in
                MainActor.assumeIsolated { self?.scheduleReload(changed: paths) }
            }
        }
        reload()
    }

    var hasLibrary: Bool { !catalog.folders.isEmpty }

    func saveCatalog() { catalog.save(to: catalogURL) }

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
                    let p = existing[item.url].flatMap { $0.ref == item.ref ? $0 : nil }
                        ?? Photo(url: item.url, ref: item.ref, sidecar: item.sidecar ?? Sidecar())
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
                self.isLoading = false
                self.keepCurrentVisible()
                self.backfillFingerprints()
                completion?()
            }
        }
    }

    struct ScannedPhoto: Sendable {
        let url: URL
        let ref: PhotoRef
        let sidecar: Sidecar?
    }

    nonisolated static func scanCatalog(_ catalog: Catalog, known: Set<URL>, only: Set<UUID>? = nil) -> [ScannedPhoto] {
        var seen = Set<String>()
        var entries: [(url: URL, ref: PhotoRef)] = []
        for folder in catalog.folders where folder.exists && (only?.contains(folder.id) ?? true) {
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
            box.set(i, SidecarFiles.read(for: entries[i].url))
        }
        return entries.indices.map { ScannedPhoto(url: entries[$0].url, ref: entries[$0].ref, sidecar: box.get($0)) }
    }

    private final class SidecarBox: @unchecked Sendable {
        private var items: [Sidecar?]
        private let lock = NSLock()
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ s: Sidecar?) { lock.lock(); items[i] = s; lock.unlock() }
        func get(_ i: Int) -> Sidecar? { lock.lock(); defer { lock.unlock() }; return items[i] }
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
        catalog.folders.removeAll { $0.id == id }
        for i in catalog.collections.indices {
            catalog.collections[i].members.removeAll { $0.folder == id }
        }
        catalog.fingerprints = catalog.fingerprints.filter { !$0.key.hasPrefix(id.uuidString + "/") }
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
        pendingSaves[photo.url]?.cancel()
        let sidecar = photo.sidecar
        let url = photo.url
        if history { historyDirty.insert(url) }
        let withHistory = historyDirty.contains(url)
        let token = UUID()
        let work = DispatchWorkItem { [weak self] in
            LibraryStore.writeSidecar(sidecar, for: url, history: withHistory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.didWrite(url, token: token) }
            }
        }
        pendingSaves[url] = work
        pendingTokens[url] = token
        unsavedCount = pendingSaves.count
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func didWrite(_ url: URL, token: UUID) {
        guard pendingTokens[url] == token else { return }
        pendingTokens[url] = nil
        historyDirty.remove(url)
        pendingSaves[url] = nil
        unsavedCount = pendingSaves.count
        lastSaved = Date()
    }

    func flushSaves() {
        commitAllPending()
        for (url, work) in pendingSaves {
            work.cancel()
            if let photo = photoByURL[url] {
                LibraryStore.writeSidecar(photo.sidecar, for: url, history: historyDirty.contains(url))
            }
        }
        pendingSaves = [:]
        pendingTokens = [:]
        historyDirty = []
        if unsavedCount != 0 { unsavedCount = 0; lastSaved = Date() }
    }

    /// ⌘S: everything is saved automatically, but this writes it out right now and says so.
    func saveNow() {
        flushSaves()
        saveCatalog()
        lastSaved = Date()
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.savedFlash = false }
    }

    nonisolated static func writeSidecar(_ sidecar: Sidecar, for url: URL, history: Bool) {
        SidecarFiles.write(sidecar, for: url, history: history)
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
            do {
                try Self.trashFile(p.url)
                for sidecar in SidecarFiles.all(for: p.url) where fm.fileExists(atPath: sidecar.path) { try? Self.trashFile(sidecar) }
                moved.append(p)
            } catch {
                failed.append(p.url.lastPathComponent)
            }
        }
        unsavedCount = pendingSaves.count
        guard !moved.isEmpty else { return failed }

        catalog.forget(Set(moved.map(\.ref)))
        saveCatalog()
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

    static let historyLimit = 100
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
    }

    /// Sets a photo's edits as one labelled step (paste, presets, snapshots, reset).
    // MARK: - Auto adjustments

    /// White balance that makes the clicked spot neutral gray (`p` normalized in the cropped photo).
    func pickWhiteBalance(at p: NormPoint, using source: ImageSource) {
        pickingWhite = false
        guard let photo = current else { return }
        let half = 0.008
        let region = CGRect(x: p.x - half, y: p.y - half, width: half * 2, height: half * 2)
        let wb = AutoAdjust.whiteBalance(source: source, adjustments: photo.adjustments, region: region)
        var a = photo.adjustments
        a.temperature = wb.temperature; a.tint = wb.tint
        applyStep(photo, a, label: "White balance (picked)")
    }

    func autoWhiteBalance(using source: ImageSource) {
        guard let photo = current else { return }
        let wb = AutoAdjust.whiteBalance(source: source, adjustments: photo.adjustments, region: nil)
        var a = photo.adjustments
        a.temperature = wb.temperature; a.tint = wb.tint
        applyStep(photo, a, label: "Auto white balance")
    }

    func autoTone(using source: ImageSource) {
        guard let photo = current else { return }
        let t = AutoAdjust.tone(source: source, adjustments: photo.adjustments)
        var a = photo.adjustments
        a.exposure = t.exposure; a.contrast = t.contrast; a.highlights = t.highlights; a.shadows = t.shadows
        applyStep(photo, a, label: "Auto tone")
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
        guard let data = try? Data(contentsOf: Self.presetsURL),
              let list = try? JSONDecoder().decode([Preset].self, from: data) else { return }
        presets = list
    }

    private func savePresets() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(presets) { try? data.write(to: Self.presetsURL, options: .atomic) }
    }
}

struct TrashRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    /// Came from "Delete Rejected…" (changes the wording).
    let rejectedOnly: Bool
}
