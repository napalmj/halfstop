import Foundation
import Observation
import AppKit

enum ViewMode { case library, edit }

enum PanelTab: String { case quick, detailed }

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
    // Folder contents
    private(set) var folder: URL?
    private(set) var photos: [Photo] = []
    private(set) var isLoading = false

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

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSaves() }
        }
        loadPresets()
        if let path = UserDefaults.standard.string(forKey: "lastFolder") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { open(folder: url) }
        }
    }

    // MARK: - Derived

    var visiblePhotos: [Photo] {
        photos.filter { p in
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

    // MARK: - Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos"
        if panel.runModal() == .OK, let url = panel.url { open(folder: url) }
    }

    func open(folder url: URL) {
        flushSaves()
        folder = url
        isLoading = true
        photos = []
        currentID = nil
        selection = []
        mode = .library
        isCropping = false
        UserDefaults.standard.set(url.path, forKey: "lastFolder")

        Task.detached(priority: .userInitiated) {
            let loaded = LibraryStore.scan(folder: url)
            await MainActor.run {
                guard self.folder == url else { return }
                self.photos = loaded.map { Photo(url: $0.0, sidecar: $0.1) }
                self.currentID = self.photos.first?.url
                if let first = self.currentID { self.selection = [first] }
                self.isLoading = false
            }
        }
    }

    nonisolated private static func scan(folder: URL) -> [(URL, Sidecar)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let files = entries
            .filter { ImageFormats.all.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let decoder = JSONDecoder()
        return files.map { url in
            let sidecarURL = sidecarURL(for: url)
            let sidecar = (try? Data(contentsOf: sidecarURL)).flatMap { try? decoder.decode(Sidecar.self, from: $0) } ?? Sidecar()
            return (url, sidecar)
        }
    }

    nonisolated static func sidecarURL(for photo: URL) -> URL {
        photo.deletingLastPathComponent()
            .appendingPathComponent(".pixon", isDirectory: true)
            .appendingPathComponent(photo.lastPathComponent + ".json")
    }

    // MARK: - Persistence

    func scheduleSave(_ photo: Photo) {
        pendingSaves[photo.url]?.cancel()
        let sidecar = photo.sidecar
        let url = photo.url
        let work = DispatchWorkItem { LibraryStore.write(sidecar, for: url) }
        pendingSaves[url] = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushSaves() {
        for (url, work) in pendingSaves {
            work.cancel()
            if let photo = photos.first(where: { $0.url == url }) {
                LibraryStore.write(photo.sidecar, for: url)
            }
        }
        pendingSaves = [:]
    }

    nonisolated private static func write(_ sidecar: Sidecar, for url: URL) {
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
