import Foundation
import Observation
import AppKit

enum ViewMode { case library, edit }

enum PanelTab: String { case quick, detailed }

enum LibrarySource: Hashable {
    case all, lastImport
    case folder(UUID)
    case collection(UUID)
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
    var photos: [Photo] = []
    @ObservationIgnored private var photoByRef: [PhotoRef: Photo] = [:]
    private(set) var isLoading = false
    var source: LibrarySource = .all {
        didSet { if oldValue != source { selection = []; keepCurrentVisible() } }
    }
    var showSidebar = true
    var showImport = false
    /// Folder to prefill in the import sheet (e.g. from drag and drop).
    var importPrefill: URL?
    @ObservationIgnored let catalogURL: URL
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var reloadPending = false

    // Navigation
    var mode: ViewMode = .library
    var currentID: URL?
    var selection: Set<URL> = []
    private var selectionAnchor: URL?

    // Filtering
    var filter: LibraryFilter = .all { didSet { keepCurrentVisible() } }
    var minRating = 0 { didSet { keepCurrentVisible() } }
    var hideRejected = false { didSet { keepCurrentVisible() } }

    // Editor state
    var isCropping = false { didSet { if isCropping { activeMaskID = nil } } }
    var showBefore = false
    var thumbnailSize: Double = 200
    var panelTab: PanelTab = .quick { didSet { if panelTab == .quick { activeMaskID = nil } } }
    /// Mask currently being edited; nil = whole photo.
    var activeMaskID: UUID? { didSet { if activeMaskID != nil { isCropping = false } } }
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
    private var undoStack: [Adjustments] = []
    private var redoStack: [Adjustments] = []
    private var undoOwner: URL?

    @ObservationIgnored private var pendingSaves: [URL: DispatchWorkItem] = [:]

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

    var visiblePhotos: [Photo] {
        let base: [Photo]
        switch source {
        case .all:
            base = photos
        case .lastImport:
            base = (catalog.lastImport?.refs ?? []).compactMap { photoByRef[$0] }
        case .folder(let id):
            base = photos.filter { $0.ref.folder == id }
        case .collection(let id):
            base = (catalog.collections.first { $0.id == id }?.members ?? []).compactMap { photoByRef[$0] }
        }
        return base.filter { p in
            if p.rating < minRating { return false }
            if hideRejected && p.flag == .reject && filter != .rejected { return false }
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
        return photos.first { $0.url == currentID }
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
                self.photoByRef = Dictionary(list.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
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
        var items = urls.compactMap { u in photos.first { $0.url == u } }
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
        let work = DispatchWorkItem { LibraryStore.writeSidecar(sidecar, for: url) }
        pendingSaves[url] = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushSaves() {
        for (url, work) in pendingSaves {
            work.cancel()
            if let photo = photos.first(where: { $0.url == url }) {
                LibraryStore.writeSidecar(photo.sidecar, for: url)
            }
        }
        pendingSaves = [:]
    }

    nonisolated static func writeSidecar(_ sidecar: Sidecar, for url: URL) {
        let dest = sidecarURL(for: url)
        let fm = FileManager.default
        if sidecar.rating == 0 && sidecar.flag == .none && sidecar.adjustments.isDefault {
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
        if currentID != url { isCropping = false; showBefore = false; activeMaskID = nil }
        currentID = url
    }

    private func keepCurrentVisible() {
        let list = visiblePhotos
        if let currentID, list.contains(where: { $0.url == currentID }) { return }
        setCurrent(list.first?.url)
        selection = currentID.map { [$0] } ?? []
    }

    // MARK: - Culling

    func setRating(_ rating: Int) {
        let targets = self.targets
        for p in targets { p.rating = (targets.count == 1 && p.rating == rating) ? 0 : rating; scheduleSave(p) }
    }

    func setFlag(_ flag: Flag) {
        for p in targets { p.flag = flag; scheduleSave(p) }
    }

    // MARK: - Editing

    /// Call before a change that should be one undo step (e.g. when a slider drag begins).
    func checkpoint() {
        guard let photo = current else { return }
        if undoOwner != photo.url { undoStack = []; redoStack = []; undoOwner = photo.url }
        if undoStack.last != photo.adjustments { undoStack.append(photo.adjustments) }
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
    }

    func edit(_ change: (inout Adjustments) -> Void) {
        guard let photo = current else { return }
        var a = photo.adjustments
        change(&a)
        guard a != photo.adjustments else { return }
        photo.adjustments = a
        scheduleSave(photo)
    }

    /// Binding-friendly accessor for a single slider value.
    func value(_ keyPath: WritableKeyPath<Adjustments, Double>) -> Double {
        current?.adjustments[keyPath: keyPath] ?? 0
    }

    func set(_ keyPath: WritableKeyPath<Adjustments, Double>, _ value: Double) {
        edit { $0[keyPath: keyPath] = value }
    }

    var canUndo: Bool { undoOwner == currentID && !undoStack.isEmpty }
    var canRedo: Bool { undoOwner == currentID && !redoStack.isEmpty }

    func undo() {
        guard let photo = current, canUndo, let previous = undoStack.popLast() else { return }
        redoStack.append(photo.adjustments)
        photo.adjustments = previous
        scheduleSave(photo)
    }

    func redo() {
        guard let photo = current, canRedo, let next = redoStack.popLast() else { return }
        undoStack.append(photo.adjustments)
        photo.adjustments = next
        scheduleSave(photo)
    }

    func resetAdjustments() {
        checkpoint()
        for p in targets { p.adjustments = Adjustments(); scheduleSave(p) }
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
        checkpoint()
        for p in targets {
            p.adjustments = clipboard.withCrop(from: p.adjustments)
            scheduleSave(p)
        }
    }

    func apply(_ preset: Preset) {
        checkpoint()
        for p in targets {
            p.adjustments = preset.adjustments.asPreset(onto: p.adjustments)
            scheduleSave(p)
        }
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
