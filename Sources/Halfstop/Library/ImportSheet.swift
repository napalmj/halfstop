import SwiftUI
import AppKit

struct ImportSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var folder: URL?
    @State private var includeSubfolders = true
    @State private var scan: ImportScan?
    @State private var scanning = false
    @State private var skipDuplicates = true
    @State private var presetID: UUID?
    @State private var rename = false
    @State private var pattern = RenamePattern.dateSequence
    @State private var customName = ""
    @State private var collectionID: UUID?
    @State private var importing = false
    @State private var result: ImportResult?
    @State private var previewLine = ""

    private var newCount: Int { scan?.newFiles(skipDuplicates: skipDuplicates).count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import photos").font(.headline)
            Text("Photos stay where they are. Halfstop remembers the folder and picks up new files added to it.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                LabeledContent("Folder") {
                    HStack {
                        Text(folder.map { $0.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "None")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(folder == nil ? .secondary : .primary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Include subfolders", isOn: $includeSubfolders)
                if folder != nil {
                    LabeledContent("Found") { status }
                }
                Toggle(isOn: $skipDuplicates) {
                    Text("Skip duplicates")
                    if let d = scan?.duplicates.count, d > 0 {
                        Text("\(d) already in your library under another name")
                    }
                }
                Picker("Apply preset", selection: $presetID) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle(isOn: $rename) {
                    Text("Rename files")
                    Text("Renames the original files on disk. You can revert this from Last import.")
                }
                if rename {
                    Picker("Pattern", selection: $pattern) {
                        ForEach(RenamePattern.allCases) { Text($0.label).tag($0) }
                    }
                    if pattern == .nameSequence {
                        TextField("Name", text: $customName, prompt: Text("japan"))
                    }
                    if !previewLine.isEmpty {
                        LabeledContent("Example") {
                            Text(previewLine).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Add to collection", selection: $collectionID) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.catalog.collections) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            .formStyle(.grouped)

            if let result {
                Text(summary(result))
                    .font(.system(size: 12))
                    .foregroundStyle(result.errors.isEmpty ? Color.secondary : Color.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importing ? "Importing…" : "Import \(newCount)", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(scan == nil || scanning || importing || newCount == 0)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let prefill = store.importPrefill {
                folder = prefill
                store.importPrefill = nil
            }
            collectionID = nil
            if folder == nil {
                DispatchQueue.main.async { chooseFolder() }
            }
        }
        .task(id: ScanKey(folder: folder, includeSubfolders: includeSubfolders)) { await rescan() }
        .task(id: PreviewKey(scanFiles: scan?.files.count ?? 0, rename: rename, pattern: pattern, name: customName)) { await updatePreview() }
    }

    @ViewBuilder
    private var status: some View {
        if scanning {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking for photos…").foregroundStyle(.secondary) }
        } else if let scan {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(scan.files.count) photos · \(newCount) new")
                if !scan.alreadyInLibrary.isEmpty {
                    Text("\(scan.alreadyInLibrary.count) already in your library").foregroundStyle(.secondary).font(.system(size: 11))
                }
                if let covered = scan.coveredBy {
                    Text("Inside “\(covered)”, which is already imported").foregroundStyle(.secondary).font(.system(size: 11))
                }
            }
        }
    }

    private struct ScanKey: Equatable { let folder: URL?; let includeSubfolders: Bool }
    private struct PreviewKey: Equatable { let scanFiles: Int; let rename: Bool; let pattern: RenamePattern; let name: String }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder of photos to import"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        } else if folder == nil {
            dismiss()
        }
    }

    private func rescan() async {
        guard let folder else { scan = nil; return }
        scanning = true
        result = nil
        let s = await store.scanForImport(folder, includeSubfolders: includeSubfolders)
        guard !Task.isCancelled else { return }
        scan = s
        scanning = false
    }

    private func updatePreview() async {
        guard rename, let scan, let first = scan.newFiles(skipDuplicates: skipDuplicates).first else { previewLine = ""; return }
        let url = scan.folder.appendingPathComponent(first)
        let date = await Task.detached { LibraryFiles.captureDate(url) }.value
        let plan = RenamePattern.plan([(first, date)], pattern: pattern, customName: customName)
        let old = (first as NSString).lastPathComponent
        let new = ((plan[first] ?? first) as NSString).lastPathComponent
        previewLine = "\(old) → \(new)"
    }

    private func run() {
        guard let scan else { return }
        importing = true
        var options = ImportOptions()
        options.skipDuplicates = skipDuplicates
        options.preset = store.presets.first { $0.id == presetID }
        options.rename = rename ? pattern : nil
        options.customName = customName
        options.collection = collectionID
        Task {
            let r = await store.performImport(scan, options: options)
            importing = false
            result = r
            if r.errors.isEmpty { dismiss() }
        }
    }

    private func summary(_ r: ImportResult) -> String {
        var parts = ["Imported \(r.imported)"]
        if r.skipped > 0 { parts.append("skipped \(r.skipped)") }
        if r.renamed > 0 { parts.append("renamed \(r.renamed)") }
        if !r.errors.isEmpty { parts.append("\(r.errors.count) problems: " + r.errors.prefix(3).joined(separator: "; ")) }
        return parts.joined(separator: ", ")
    }
}
