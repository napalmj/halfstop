import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryGridView: View {
    @Environment(LibraryStore.self) private var store
    private let spacing: CGFloat = 14
    private let padding: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let size = store.thumbnailSize
            let columns = max(1, Int((geo.size.width - padding * 2 + spacing) / (size + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
                        ForEach(store.visiblePhotos) { photo in
                            GridCell(photo: photo,
                                     selected: store.selection.contains(photo.url),
                                     isCurrent: store.currentID == photo.url)
                                .id(photo.url)
                        }
                    }
                    .padding(padding)
                }
                .onChange(of: store.currentID) { _, id in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
                .onAppear { proxy.scrollTo(store.currentID, anchor: .center) }
            }
            .onAppear { store.gridColumns = columns }
            .onChange(of: columns) { _, c in store.gridColumns = c }
        }
        .background(Theme.background)
        .overlay {
            if store.isLoading {
                ProgressView()
            } else if store.visiblePhotos.isEmpty && !store.photos.isEmpty {
                Text("No photos match this filter").foregroundStyle(Theme.secondary)
            } else if store.visiblePhotos.isEmpty {
                if case .collection = store.source {
                    Text("Drag photos here, or select them and press B").foregroundStyle(Theme.secondary)
                } else {
                    Text("No photos here yet").foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

private struct GridCell: View {
    @Environment(LibraryStore.self) private var store
    let photo: Photo
    let selected: Bool
    let isCurrent: Bool
    @State private var hovering = false

    /// Right-clicking a selected photo acts on the whole selection, otherwise just this one.
    private var contextTargets: [Photo] {
        selected ? store.visiblePhotos.filter { store.selection.contains($0.url) } : [photo]
    }

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(photo: photo)
                .aspectRatio(3 / 2, contentMode: .fit)
                .padding(8)
                .background(selected ? Theme.panelRaised : (hovering ? Theme.panel : .clear),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isCurrent ? Theme.accent : (selected ? Theme.accent.opacity(0.4) : .clear), lineWidth: 2))
                .overlay(alignment: .bottomLeading) { StarsBadge(rating: photo.rating).padding(6) }
                .overlay(alignment: .topTrailing) { FlagBadge(flag: photo.flag).padding(4) }
                .overlay(alignment: .bottomTrailing) {
                    if !photo.adjustments.isDefault { EditedBadge().padding(12) }
                }
                .opacity(photo.flag == .reject ? 0.35 : 1)
            Text(photo.name)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            if NSApp.currentEvent?.clickCount == 2 {
                store.open(photo)
            } else {
                store.select(photo, extend: flags.contains(.shift), toggle: flags.contains(.command))
            }
        }
        .draggable(photo.url) {
            ThumbnailView(photo: photo, maxSize: 200)
                .frame(width: 120, height: 80)
                .overlay(alignment: .topTrailing) {
                    if store.selection.count > 1 && selected {
                        Text("\(store.selection.count)")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
        }
        .contextMenu {
            Button("Edit") { store.open(photo) }
            Menu("Add to collection") {
                ForEach(store.catalog.collections) { c in
                    Button(c.name) { store.addToCollection(c.id, contextTargets) }
                }
                if !store.catalog.collections.isEmpty { Divider() }
                Button("New collection…") {
                    if let id = store.createCollection(named: "New collection", with: contextTargets) {
                        store.source = .collection(id)
                    }
                }
            }
            if case .collection(let id) = store.source {
                Button("Remove from collection") { store.removeFromCollection(id, contextTargets) }
            }
            Divider()
            Button("Pick") { store.select(photo); store.setFlag(.pick) }
            Button("Reject") { store.select(photo); store.setFlag(.reject) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
        }
    }
}

/// Marks a photo that has edits.
struct EditedBadge: View {
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "slider.horizontal.3")
            if !compact { Text("Edited") }
        }
        .font(.system(size: compact ? 8.5 : 10, weight: .semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, compact ? 2 : 3)
        .background(Theme.accent, in: Capsule())
        .shadow(color: .black.opacity(0.4), radius: 1.5)
        .help("This photo has edits")
    }
}

/// "Saved" / "Saving…" in the top bar. Edits save automatically next to each photo.
private struct SaveStatus: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let saving = store.unsavedCount > 0
        HStack(spacing: 4) {
            Image(systemName: saving ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
            Text(saving ? "Saving…" : "Saved")
        }
        .font(.system(size: 11.5, weight: store.savedFlash ? .semibold : .regular))
        .foregroundStyle(store.savedFlash ? Theme.accent : Theme.secondary)
        .animation(.easeOut(duration: 0.2), value: store.savedFlash)
        .help(helpText)
    }

    private var helpText: String {
        var t = "Edits save automatically next to your photos (⌘S saves right away)."
        if let d = store.lastSaved {
            let f = RelativeDateTimeFormatter()
            t += " Last saved \(f.localizedString(for: d, relativeTo: Date()))."
        }
        return t
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 12) {
            Color.clear.frame(width: 64, height: 1) // traffic lights
            if store.hasLibrary {
                let leftShown = store.mode == .library ? store.showSidebar : store.showHistory
                Button {
                    if store.mode == .library { store.showSidebar.toggle() } else { store.showHistory.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(leftShown ? Theme.text : Theme.secondary)
                .help(store.mode == .library ? "Show or hide sidebar (⇧⌘S)" : "Show or hide history (⇧⌘S)")
                HStack(spacing: 6) {
                    Text(store.sourceTitle).fontWeight(.semibold).foregroundStyle(Theme.text)
                    Text("\(store.visiblePhotos.count) photos").foregroundStyle(Theme.secondary)
                    if store.mode == .library && store.selection.count > 1 {
                        Text("· \(store.selection.count) selected").foregroundStyle(Theme.secondary)
                    }
                }
            }
            Spacer()
            if store.hasLibrary {
                ModeSwitch()
            }
            Spacer()
            if store.hasLibrary {
                if store.mode == .library, let target = store.targetCollection {
                    Button { store.addSelectionToTarget() } label: {
                        Label("Add to \(target.name)", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .help("Add the selection to “\(target.name)” (B)")
                }
                SaveStatus()
                Button { store.showImportSheet() } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text.opacity(0.85))
                .help("Import photos (⌘I)")
                if store.mode == .library {
                    Slider(value: $store.thumbnailSize, in: 120...360)
                        .controlSize(.mini)
                        .frame(width: 90)
                        .help("Thumbnail size")
                }
                Menu {
                    Picker("Show", selection: $store.filter) {
                        ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Rating", selection: $store.minRating) {
                        Text("Any rating").tag(0)
                        ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0) + " and up").tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Edits", selection: $store.editsFilter) {
                        ForEach(EditsFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Toggle("Hide rejected", isOn: $store.hideRejected)
                } label: {
                    Label(filterLabel, systemImage: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    store.showExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 6))
                .disabled(store.targets.isEmpty)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Theme.panel)
    }

    private var filterLabel: String {
        var parts: [String] = []
        if store.filter != .all { parts.append(store.filter.label) }
        if store.minRating > 0 { parts.append("\(store.minRating)★+") }
        if store.editsFilter == .edited { parts.append("Edited") }
        if store.editsFilter == .unedited { parts.append("Not edited") }
        return parts.isEmpty ? "All" : parts.joined(separator: " · ")
    }
}

private struct ModeSwitch: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            item("Library", "G", .library)
            item("Edit", "E", .edit)
        }
        .padding(2)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
    }

    private func item(_ title: String, _ key: String, _ mode: ViewMode) -> some View {
        Text(title)
            .font(.system(size: 12, weight: store.mode == mode ? .semibold : .regular))
            .foregroundStyle(store.mode == mode ? Theme.text : Theme.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(store.mode == mode ? Theme.panelRaised : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { store.mode = mode }
            .help("\(title) (\(key))")
    }
}

// MARK: - Empty state

struct WelcomeView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text("Import your photos")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("Photos stay where they are on disk. Edits are saved next to them in a hidden .pixon folder.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Import photos…") { store.showImportSheet() }
                .keyboardShortcut("i")
                .controlSize(.large)
            Text("or drop a folder here")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

// MARK: - Save preset

struct SavePresetSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save preset").font(.headline)
            Text("Saves the current global look. Crop and masks aren't included.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("Moody blue", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.saveCurrentAsPreset(named: name)
        dismiss()
    }
}

// MARK: - Export

struct ExportSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSheet.loadSettings()
    @State private var progress: Double?
    @State private var done: [URL] = []
    @State private var errors: [String] = []
    @State private var targets: [(url: URL, adjustments: Adjustments)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(targets.count == 1 ? "Export 1 photo" : "Export \(targets.count) photos").font(.headline)

            Form {
                Picker("Format", selection: $settings.format) {
                    ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                }
                if settings.format != .tiff {
                    HStack {
                        Slider(value: $settings.quality, in: 0.5...1) { Text("Quality") }
                        Text("\(Int(settings.quality * 100))").monospacedDigit().frame(width: 30)
                    }
                }
                Picker("Size", selection: $settings.longEdge) {
                    Text("Original").tag(0)
                    Text("Long edge 4096 px").tag(4096)
                    Text("Long edge 2048 px").tag(2048)
                    Text("Long edge 1080 px").tag(1080)
                }
                Toggle("Display P3 (wide color)", isOn: $settings.useDisplayP3)
                LabeledContent("Folder") {
                    HStack {
                        Text(destination?.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Choose…")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
            .formStyle(.grouped)

            if let progress {
                ProgressView(value: progress)
                if progress >= 1 {
                    HStack {
                        Text(errors.isEmpty ? "Exported \(done.count) photos" : "Exported \(done.count), \(errors.count) failed")
                            .font(.system(size: 12))
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(done) }
                    }
                    ForEach(errors, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.red) }
                }
            }

            HStack {
                Spacer()
                Button(progress == nil || progress! >= 1 ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination == nil || targets.isEmpty || (progress != nil && progress! < 1))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            targets = store.targets.map { ($0.url, $0.adjustments) }
            if settings.destinationPath == nil, let first = store.targets.first {
                settings.destinationPath = first.url.deletingLastPathComponent().appendingPathComponent("Exports").path
            }
        }
        .onChange(of: settings.format) { save() }
        .onChange(of: settings.quality) { save() }
        .onChange(of: settings.longEdge) { save() }
        .onChange(of: settings.useDisplayP3) { save() }
    }

    private var destination: URL? { settings.destinationPath.map { URL(fileURLWithPath: $0) } }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.destinationPath = url.path
            save()
        }
    }

    private func run() {
        guard let dest = destination else { return }
        save()
        let jobs = targets
        let settings = self.settings
        progress = 0
        done = []
        errors = []
        Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for (i, job) in jobs.enumerated() {
                do {
                    let out = try Exporter.export(job, settings: settings, to: dest)
                    await MainActor.run { done.append(out) }
                } catch {
                    await MainActor.run { errors.append("\(job.url.lastPathComponent): \(error.localizedDescription)") }
                }
                await MainActor.run { progress = Double(i + 1) / Double(jobs.count) }
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "exportSettings") }
    }

    private static func loadSettings() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: "exportSettings"),
              let s = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return ExportSettings() }
        return s
    }
}
