import SwiftUI
import AppKit

struct LibrarySidebar: View {
    @Environment(LibraryStore.self) private var store
    @State private var newCollectionName: String?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var deleting: PhotoCollection?
    @State private var removingFolder: CatalogFolder?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                item(.all, icon: "photo.on.rectangle", title: "All photos")
                if store.catalog.lastImport != nil {
                    item(.lastImport, icon: "clock", title: "Last import")
                        .contextMenu {
                            Button("Revert file names") { Task { await store.revertLastImportNames() } }
                                .disabled(!store.canRevertLastImportNames)
                        }
                }

                header("Folders") { store.showImportSheet() }
                    .help("Import a folder (⌘I)")
                ForEach(store.catalog.folders) { folder in
                    folderRow(folder)
                }

                header("Collections") {
                    newCollectionName = ""
                    fieldFocused = true
                }
                .help("New collection")
                if newCollectionName != nil {
                    TextField("Collection name", text: Binding(get: { newCollectionName ?? "" }, set: { newCollectionName = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($fieldFocused)
                        .onSubmit {
                            let members = store.selectedPhotos
                            if let id = store.createCollection(named: newCollectionName ?? "", with: members) {
                                store.source = .collection(id)
                            }
                            newCollectionName = nil
                        }
                        .onExitCommand { newCollectionName = nil }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                ForEach(store.catalog.collections) { collection in
                    collectionRow(collection)
                }
                if store.catalog.collections.isEmpty && newCollectionName == nil {
                    Text("Select photos and click + to make a collection.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                }
                if let target = store.targetCollection {
                    Text("B adds to “\(target.name)”")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .frame(width: 220)
        .background(Theme.panel)
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete collection", role: .destructive) {
                if let d = deleting { store.deleteCollection(d.id) }
                deleting = nil
            }
        } message: {
            Text("The photos stay in your library and on disk.")
        }
        .confirmationDialog("Remove “\(removingFolder?.name ?? "")” from the library?", isPresented: Binding(get: { removingFolder != nil }, set: { if !$0 { removingFolder = nil } })) {
            Button("Remove folder", role: .destructive) {
                if let f = removingFolder { store.removeFolder(f.id) }
                removingFolder = nil
            }
        } message: {
            Text("Photos stay on disk with their edits. They're removed from collections.")
        }
    }

    // MARK: Rows

    private func header(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button(action: add) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func rowBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.panelRaised : .clear)
    }

    private func item(_ source: LibrarySource, icon: String, title: String) -> some View {
        let selected = store.source == source
        return HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16)
            Text(title).lineLimit(1)
            Spacer()
            Text("\(store.count(source))").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.75))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground(selected))
        .contentShape(Rectangle())
        .onTapGesture { store.source = source }
    }

    private func folderRow(_ folder: CatalogFolder) -> some View {
        let missing = !folder.exists
        return item(.folder(folder.id), icon: missing ? "exclamationmark.triangle" : "folder", title: folder.name)
            .foregroundStyle(missing ? Color.orange : Theme.text)
            .help(missing ? "Missing: \(folder.path). Right-click to locate it." : folder.path)
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                    .disabled(missing)
                Button(missing ? "Locate folder…" : "Change location…") { store.relocateFolder(folder.id) }
                Divider()
                Button("Remove from library…") { removingFolder = folder }
            }
    }

    @ViewBuilder
    private func collectionRow(_ collection: PhotoCollection) -> some View {
        let isTarget = store.catalog.targetCollection == collection.id
        if renaming == collection.id {
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($fieldFocused)
                .onSubmit { store.renameCollection(collection.id, to: renameText); renaming = nil }
                .onExitCommand { renaming = nil }
                .padding(.horizontal, 6)
        } else {
            CollectionDropRow(collection: collection, isTarget: isTarget)
                .contextMenu {
                    Button("Set as target for B") { store.setTargetCollection(collection.id) }
                        .disabled(isTarget)
                    Button("Add selected photos") { store.addToCollection(collection.id, store.selectedPhotos) }
                    Button("Rename…") { renameText = collection.name; renaming = collection.id; fieldFocused = true }
                    Divider()
                    Button("Delete collection…") { deleting = collection }
                }
        }
    }
}

/// A collection in the sidebar that accepts photos dropped from the grid.
private struct CollectionDropRow: View {
    @Environment(LibraryStore.self) private var store
    let collection: PhotoCollection
    let isTarget: Bool
    @State private var dropTargeted = false

    var body: some View {
        let source = LibrarySource.collection(collection.id)
        let selected = store.source == source
        HStack(spacing: 8) {
            Image(systemName: isTarget ? "scope" : "square.stack").frame(width: 16)
            Text(collection.name).lineLimit(1)
            Spacer()
            Text("\(store.count(source))").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.75))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.panelRaised : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(dropTargeted ? Theme.accent : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 {
                store.setTargetCollection(collection.id)
            } else {
                store.source = source
            }
        }
        .help(isTarget ? "Target collection: B adds the selection here" : "Double-click to make this the target for B")
        .dropDestination(for: URL.self) { urls, _ in
            store.dropOnCollection(collection.id, urls: urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}
