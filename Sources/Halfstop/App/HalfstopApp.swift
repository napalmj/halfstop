import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct HalfstopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: LibraryStore
    @State private var renderer = PreviewRenderer()

    init() {
        SelfTest.runIfRequested()
        Bench.runIfRequested()
        // Before the library and settings are read.
        LegacyNames.migrateAppData()
        _store = State(initialValue: LibraryStore(catalogURL: Snapshot.catalogOverride ?? Catalog.defaultURL))
    }

    var body: some Scene {
        Window("Halfstop", id: "main") {
            ContentView()
                .environment(store)
                .environment(renderer)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { HalfstopCommands(store: store) }

        Window("Halfstop Help", id: "help") {
            HelpView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 860, height: 680)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(PreviewRenderer.self) private var renderer
    @State private var keyMonitor: Any?
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            TopBar()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Group {
                if !store.hasLibrary {
                    WelcomeView()
                } else if store.mode == .library {
                    HStack(spacing: 0) {
                        if store.showSidebar {
                            LibrarySidebar()
                            Rectangle().fill(Theme.hairline).frame(width: 1)
                        }
                        LibraryGridView()
                    }
                } else {
                    EditorView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).stroke(Theme.accent, lineWidth: 3).padding(6)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
                DispatchQueue.main.async { store.showImportSheet(prefill: folder) }
            }
            return true
        }
        .sheet(isPresented: $store.showExport) { ExportSheet() }
        .sheet(isPresented: $store.showImport) { ImportSheet() }
        .sheet(isPresented: $store.showSavePreset) { SavePresetSheet() }
        .sheet(isPresented: $store.showSelectivePaste) { SelectivePasteSheet() }
        .alert(TrashText.title(store.trashRequest),
               isPresented: Binding(get: { store.trashRequest != nil }, set: { if !$0 { store.trashRequest = nil } }),
               presenting: store.trashRequest) { request in
            Button("Move to Trash", role: .destructive) {
                store.trashFailures = store.moveToTrash(request.urls)
                store.trashRequest = nil
            }
            Button("Cancel", role: .cancel) { store.trashRequest = nil }
        } message: { request in
            Text(TrashText.message(request, photos: store.photos))
        }
        .alert("Some photos couldn’t be moved to the Trash",
               isPresented: Binding(get: { !store.trashFailures.isEmpty }, set: { if !$0 { store.trashFailures = [] } })) {
            Button("OK") { store.trashFailures = [] }
        } message: {
            Text(TrashText.list(store.trashFailures) + ". They may be locked, or on a read-only drive.")
        }
        .onAppear {
            SubjectDetector.shared.onDetected = { _ in renderer.bump() }
            Snapshot.run(store: store, renderer: renderer)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                KeyHandler.handle(event, store: store) ? nil : event
            }
        }
    }
}

/// Wording for the Move to Trash warning.
enum TrashText {
    static func title(_ r: TrashRequest?) -> String {
        guard let r else { return "Move to Trash?" }
        let n = r.urls.count
        let what = r.rejectedOnly ? (n == 1 ? "rejected photo" : "rejected photos") : (n == 1 ? "photo" : "photos")
        return "Move \(n) \(what) to the Trash?"
    }

    static func message(_ r: TrashRequest, photos: [Photo]) -> String {
        let names = r.urls.map(\.lastPathComponent)
        let wanted = Set(r.urls)
        let edited = photos.filter { wanted.contains($0.url) && !$0.adjustments.isDefault }.count
        var text = names.count == 1
            ? "“\(names[0])” will be moved from its folder to the Trash, along with its Halfstop edits."
            : "\(list(names)) will be moved from their folders to the Trash, along with their Halfstop edits."
        if edited > 0 && names.count > 1 { text += " \(edited) of them \(edited == 1 ? "has" : "have") edits." }
        let one = names.count == 1
        text += one ? " It’s also removed from your collections." : " They’re also removed from your collections."
        text += "\n\nYou can put \(one ? "it" : "them") back from the Trash in Finder until you empty it."
        return text
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "“\(names[0])”"
        case 2...3: return names.dropLast().map { "“\($0)”" }.joined(separator: ", ") + " and “\(names.last!)”"
        default: return names.prefix(2).map { "“\($0)”" }.joined(separator: ", ") + " and \(names.count - 2) more"
        }
    }
}

/// Single-key shortcuts for culling and editing.
@MainActor
enum KeyHandler {
    static func handle(_ event: NSEvent, store: LibraryStore) -> Bool {
        guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil else { return false }
        if window.firstResponder is NSText { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty { return false }
        guard store.hasLibrary else { return false }

        // ↑/↓ over a slider nudge it (⇧ = 5 steps) instead of changing photos.
        if store.mode == .edit, event.keyCode == 125 || event.keyCode == 126 {
            let steps = (event.keyCode == 126 ? 1.0 : -1.0) * (event.modifierFlags.contains(.shift) ? 5 : 1)
            if SliderFocus.shared.nudge(steps) { return true }
        }

        switch event.keyCode {
        case 123: store.step(-1); return true                                         // ←
        case 124: store.step(1); return true                                          // →
        case 125: store.mode == .library ? store.stepRow(1, columns: store.gridColumns) : store.step(1); return true  // ↓
        case 126: store.mode == .library ? store.stepRow(-1, columns: store.gridColumns) : store.step(-1); return true // ↑
        case 36, 76:                                                                  // return
            if store.isCropping { store.isCropping = false }
            else if store.mode == .library, store.current != nil { store.mode = .edit }
            return true
        case 51, 117:                                                                 // delete
            // In a collection Delete only takes photos out of it; elsewhere it asks to move the files to the Trash.
            guard store.mode == .library else { return false }
            if case .collection(let id) = store.source {
                store.removeFromCollection(id, store.selectedPhotos)
            } else {
                store.requestTrash(store.selectedPhotos)
            }
            return true
        case 53:                                                                      // esc
            if store.pickingWhite { store.pickingWhite = false }
            else if store.isCropping { store.isCropping = false }
            else if store.refineMode != nil { store.refineMode = nil }
            else if store.activeMaskID != nil { store.activeMaskID = nil }
            else if store.showBefore { store.showBefore = false }
            else if store.mode == .edit { store.mode = .library }
            return true
        default: break
        }

        // Rating and flags; ⇧ (or Auto Advance) then moves on to the next photo. Digits go by key
        // code because ⇧1 types "!".
        let digits: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5]  // row + keypad
        let advance = (store.autoAdvance || event.modifierFlags.contains(.shift)) && store.targets.count <= 1
        if let rating = digits[event.keyCode] {
            store.setRating(rating)
            if advance { store.step(1) }
            return true
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return false }
        switch chars {
        case "p": store.setFlag(.pick); if advance { store.step(1) }
        case "x": store.setFlag(.reject); if advance { store.step(1) }
        case "u": store.setFlag(.none); if advance { store.step(1) }
        case "g": store.mode = .library
        case "e": if store.current != nil { store.mode = .edit }
        case "c", "r":
            guard store.current != nil else { return false }
            store.mode = .edit
            store.isCropping.toggle()
        case "\\": if store.mode == .edit { store.showBefore.toggle() }
        case "j": if store.mode == .edit { store.showClipping.toggle() }
        case "w":
            guard store.current != nil else { return false }
            store.mode = .edit
            store.isCropping = false
            store.activeMaskID = nil
            store.pickingWhite.toggle()
        case "o": if store.activeMaskID != nil { store.setOverlay(!store.showMaskOverlay) }
        case "[": store.brushSize = max(0.005, store.brushSize / 1.2)
        case "]": store.brushSize = min(0.25, store.brushSize * 1.2)
        case "b": store.addSelectionToTarget()
        case "d": store.panelTab = store.panelTab == .quick ? .detailed : .quick
        default: return false
        }
        return true
    }
}

struct HalfstopCommands: Commands {
    let store: LibraryStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Halfstop Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("Import Photos…") { store.showImportSheet() }
                .keyboardShortcut("i")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { store.saveNow() }
                .keyboardShortcut("s")
        }
        CommandGroup(after: .newItem) {
            Button("Export…") { store.showExport = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store.undo() }
                .keyboardShortcut("z")
            Button("Redo") { store.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Photo") {
            Button("Copy Settings") { store.copySettings() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste Settings") { store.pasteSettings() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Paste Selected Settings…") { store.showSelectivePaste = true }
                .keyboardShortcut("v", modifiers: [.command, .shift, .option])
                .disabled(store.clipboard == nil)
            Button("Reset All Adjustments") { store.resetAdjustments() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Save Preset…") { store.showSavePreset = true }
            Divider()
            Button("Add to Target Collection") { store.addSelectionToTarget() }
                .disabled(store.targetCollection == nil)
            Divider()
            Button(store.selectedPhotos.count > 1 ? "Move \(store.selectedPhotos.count) Photos to Trash…" : "Move to Trash…") {
                store.requestTrash(store.selectedPhotos)
            }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selectedPhotos.isEmpty)
            Button("Delete Rejected Photos…") { store.requestTrashRejected() }
                .disabled(store.rejectedInSource.isEmpty)
            Divider()
            Button("Show or Hide Sidebar / History") {
                if store.mode == .library { store.showSidebar.toggle() } else { store.showHistory.toggle() }
            }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Library") { store.mode = .library }
            Button("Edit") { store.mode = .edit }
            Divider()
            Toggle("Auto Advance After Rating", isOn: Binding(get: { store.autoAdvance }, set: { store.autoAdvance = $0 }))
            Divider()
            Button(store.showClipping ? "Hide Clipping (J)" : "Show Clipping (J)") { store.showClipping.toggle() }
                .disabled(store.mode != .edit)
        }
    }
}
