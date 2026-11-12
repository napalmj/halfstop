import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct PixonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = LibraryStore(catalogURL: Snapshot.catalogOverride ?? Catalog.defaultURL)
    @State private var renderer = PreviewRenderer()

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        Window("Pixon", id: "main") {
            ContentView()
                .environment(store)
                .environment(renderer)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { PixonCommands(store: store) }
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
        .onAppear {
            SubjectDetector.shared.onDetected = { _ in renderer.bump() }
            Snapshot.run(store: store, renderer: renderer)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                KeyHandler.handle(event, store: store) ? nil : event
            }
        }
    }
}

/// Single-key shortcuts for culling and editing (Lightroom-style).
@MainActor
enum KeyHandler {
    static func handle(_ event: NSEvent, store: LibraryStore) -> Bool {
        guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil else { return false }
        if window.firstResponder is NSText { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty { return false }
        guard store.hasLibrary else { return false }

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
            if case .collection(let id) = store.source, store.mode == .library {
                store.removeFromCollection(id, store.selectedPhotos)
                return true
            }
            return false
        case 53:                                                                      // esc
            if store.isCropping { store.isCropping = false }
            else if store.activeMaskID != nil { store.activeMaskID = nil }
            else if store.showBefore { store.showBefore = false }
            else if store.mode == .edit { store.mode = .library }
            return true
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return false }
        switch chars {
        case "0", "1", "2", "3", "4", "5": store.setRating(Int(chars)!)
        case "p": store.setFlag(.pick)
        case "x": store.setFlag(.reject)
        case "u": store.setFlag(.none)
        case "g": store.mode = .library
        case "e": if store.current != nil { store.mode = .edit }
        case "c", "r":
            guard store.current != nil else { return false }
            store.mode = .edit
            store.isCropping.toggle()
        case "\\": if store.mode == .edit { store.showBefore.toggle() }
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

struct PixonCommands: Commands {
    let store: LibraryStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Photos…") { store.showImportSheet() }
                .keyboardShortcut("i")
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
            Button("Reset All Adjustments") { store.resetAdjustments() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Save Preset…") { store.showSavePreset = true }
            Divider()
            Button("Add to Target Collection") { store.addSelectionToTarget() }
                .disabled(store.targetCollection == nil)
            Divider()
            Button("Show or Hide Sidebar") { store.showSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Library") { store.mode = .library }
            Button("Edit") { store.mode = .edit }
        }
    }
}
