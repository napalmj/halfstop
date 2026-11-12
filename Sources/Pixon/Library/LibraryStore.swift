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
    var photos: [Photo] = [] {
        didSet {
            photoByRef = Dictionary(photos.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
            photoByURL = Dictionary(photos.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }
    @ObservationIgnored private var photoByRef: [PhotoRef: Photo] = [:]
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
            watcher = FolderWatcher { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
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
            (catalog.lastImport?.refs ?? []).compactMap { photoByRef[$0] }
        case .folder(let id):
            photos.filter { $0.ref.folder == id }
        case .collection(let id):
            (catalog.collections.first { $0.id == id }?.members ?? []).compactMap { photoByRef[$0] }
        }
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

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.reload()
        }
    }

    /// Rescans every imported folder. Keeps existing Photo objects (and their unsaved state) for files still present.
    func reload(completion: (() -> Void)? = nil) {
        let catalog = self.catalog
        let existing = Dictionary(photos.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(existing.keys)
        if photos.isEmpty { isLoading = true }
        watcher?.watch(catalog.folders.filter(\.exists).map(\.path))
        Task.detached(priority: .userInitiated) {
            let found = LibraryStore.scanCatalog(catalog, known: known)
            await MainActor.run {
                var list: [Photo] = []
                for item in found {
                    if let p = existing[item.url], p.ref == item.ref {
                        list.append(p)
                    } else {
                        list.append(Photo(url: item.url, ref: item.ref, sidecar: item.sidecar ?? Sidecar()))
                    }
                }
                self.photos = list
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

    nonisolated static func scanCatalog(_ catalog: Catalog, known: Set<URL>) -> [ScannedPhoto] {
        let decoder = JSONDecoder()
        var seen = Set<String>()
        var out: [ScannedPhoto] = []
        for folder in catalog.folders where folder.exists {
            for rel in LibraryFiles.enumerate(folder.url, recursive: folder.includeSubfolders) where !folder.excluded.contains(rel) {
                let url = URL(fileURLWithPath: folder.path).appendingPathComponent(rel)
                guard seen.insert(url.path).inserted else { continue }
                var sidecar: Sidecar?
                if !known.contains(url) {
                    sidecar = (try? Data(contentsOf: sidecarURL(for: url))).flatMap { try? decoder.decode(Sidecar.self, from: $0) }
                }
                out.append(ScannedPhoto(url: url, ref: PhotoRef(folder: folder.id, path: rel), sidecar: sidecar))
            }
        }
        return out
    }

    nonisolated static func sidecarURL(for photo: URL) -> URL {
        photo.deletingLastPathComponent()
            .appendingPathComponent(".pixon", isDirectory: true)
            .appendingPathComponent(photo.lastPathComponent + ".json")
    }

    /// Computes fingerprints for library photos that don't have one yet (in the background).
    @ObservationIgnored private var fingerprinting = false
    private func backfillFingerprints() {
        guard !fingerprinting else { return }
        let missing = photos.filter { catalog.fingerprints[$0.ref.key] == nil }.map { ($0.ref, $0.url) }
        guard !missing.isEmpty else { return }
        fingerprinting = true
        Task.detached(priority: .utility) {
            var found: [String: String] = [:]
            for (ref, url) in missing {
                if let fp = LibraryFiles.fingerprint(url) { found[ref.key] = fp }
            }
            let computed = found
            await MainActor.run {
                self.catalog.fingerprints.merge(computed) { _, new in new }
                self.saveCatalog()
                self.fingerprinting = false
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

    func scheduleSave(_ photo: Photo) {
        pendingSaves[photo.url]?.cancel()
        let sidecar = photo.sidecar
        let url = photo.url
        let token = UUID()
        let work = DispatchWorkItem { [weak self] in
            LibraryStore.writeSidecar(sidecar, for: url)
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
        pendingSaves[url] = nil
        unsavedCount = pendingSaves.count
        lastSaved = Date()
    }

    func flushSaves() {
        commitAllPending()
        for (url, work) in pendingSaves {
            work.cancel()
            if let photo = photoByURL[url] {
                LibraryStore.writeSidecar(photo.sidecar, for: url)
            }
        }
        pendingSaves = [:]
        pendingTokens = [:]
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

    nonisolated static func writeSidecar(_ sidecar: Sidecar, for url: URL) {
        let dest = sidecarURL(for: url)
        let fm = FileManager.default
        if sidecar.isEmpty {
            try? fm.removeItem(at: dest)
            return
        }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sidecar) { try? data.write(to: dest, options: .atomic) }
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

    func step(_ delta: Int) {
        let list = visiblePhotos
        guard !list.isEmpty else { return }
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

    /// Moves the photo files (and their `.pixon` sidecars) to the Trash, where Finder can put them back,
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
            pendingSaves[p.url]?.cancel(); pendingSaves[p.url] = nil; pendingTokens[p.url] = nil
            pendingCommits[p.url]?.cancel(); pendingCommits[p.url] = nil
            do {
                try Self.trashFile(p.url)
                let sidecar = Self.sidecarURL(for: p.url)
                if fm.fileExists(atPath: sidecar.path) { try? Self.trashFile(sidecar) }
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
        scheduleSave(photo)
    }

    /// Sets a photo's edits as one labelled step (paste, presets, snapshots, reset).
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
        scheduleSave(photo)
    }

    /// Drops the steps after the current one right away.
    func trimHistoryAfterCurrent() {
        guard let photo = current else { return }
        commitPending(photo)
        photo.history = Array(photo.history.prefix(photo.historyIndex + 1))
        scheduleSave(photo)
    }

    /// Forgets the history, keeping the current edits as the new starting point.
    func clearHistory() {
        guard let photo = current else { return }
        commitPending(photo)
        photo.history = [HistoryStep(label: "History cleared", adjustments: photo.adjustments)]
        photo.historyIndex = 0
        scheduleSave(photo)
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
            .appendingPathComponent("Pixon", isDirectory: true)
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
