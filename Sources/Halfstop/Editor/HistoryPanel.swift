import SwiftUI

/// Left-hand panel in the editor: snapshots on top, the edit history below.
/// Click a step to go back to it; editing from there trims the later (struck-out) steps.
struct HistoryPanel: View {
    @Environment(LibraryStore.self) private var store
    @State private var newSnapshotName: String?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var confirmClear = false
    @FocusState private var fieldFocused: Bool

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let photo = store.current {
                header
                snapshots(photo)
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 8)
                history(photo)
            } else {
                Spacer()
            }
        }
        .frame(width: 230)
        .background(Theme.panel)
        .confirmationDialog("Clear the history for this photo?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { store.clearHistory() }
        } message: {
            Text("Your current edits stay. Snapshots are kept.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("HISTORY")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.text.opacity(0.8))
            Spacer()
            Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!store.canUndo)
                .help("Undo (⌘Z)")
            Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!store.canRedo)
                .help("Redo (⇧⌘Z)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Theme.text.opacity(0.85))
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: Snapshots

    @ViewBuilder
    private func snapshots(_ photo: Photo) -> some View {
        HStack {
            Text("Snapshots").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            Spacer()
            Button {
                newSnapshotName = ""
                fieldFocused = true
            } label: {
                Label("Save", systemImage: "camera")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.text.opacity(0.85))
            .help("Save the current edits as a named version")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)

        if newSnapshotName != nil {
            TextField("Warm version", text: Binding(get: { newSnapshotName ?? "" }, set: { newSnapshotName = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($fieldFocused)
                .onSubmit {
                    store.saveSnapshot(named: newSnapshotName ?? "")
                    newSnapshotName = nil
                }
                .onExitCommand { newSnapshotName = nil }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }

        if photo.snapshots.isEmpty && newSnapshotName == nil {
            Text("Save named versions to come back to. They stay when history is trimmed.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
        }
        VStack(spacing: 1) {
            ForEach(photo.snapshots) { snap in
                if renaming == snap.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($fieldFocused)
                        .onSubmit { store.renameSnapshot(snap.id, to: renameText); renaming = nil }
                        .onExitCommand { renaming = nil }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "photo").frame(width: 14)
                        Text(snap.name).lineLimit(1)
                        Spacer()
                        Text(Self.time.string(from: snap.date)).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(photo.adjustments == snap.adjustments ? Theme.text : Theme.text.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(photo.adjustments == snap.adjustments ? Theme.panelRaised : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { store.applySnapshot(snap) }
                    .help("Apply “\(snap.name)” (adds a history step)")
                    .contextMenu {
                        Button("Apply") { store.applySnapshot(snap) }
                        Button("Rename…") { renameText = snap.name; renaming = snap.id; fieldFocused = true }
                        Divider()
                        Button("Delete snapshot", role: .destructive) { store.deleteSnapshot(snap.id) }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: History

    private func history(_ photo: Photo) -> some View {
        let steps = Array(photo.history.enumerated()).reversed()
        let hasFuture = photo.historyIndex < photo.history.count - 1
        return VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(steps), id: \.element.id) { index, step in
                            stepRow(step, index: index, current: index == photo.historyIndex, future: index > photo.historyIndex)
                                .id(step.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                }
                .onChange(of: photo.historyIndex) { _, i in
                    if photo.history.indices.contains(i) {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(photo.history[i].id) }
                    }
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                if hasFuture {
                    Text("Struck-out steps are removed when you make a new edit.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if hasFuture {
                        Button("Remove later steps") { store.trimHistoryAfterCurrent() }
                    }
                    Spacer()
                    Button("Clear…") { confirmClear = true }
                        .disabled(photo.history.count <= 1)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func stepRow(_ step: HistoryStep, index: Int, current: Bool, future: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(current ? Theme.accent : Theme.secondary.opacity(future ? 0.3 : 0.6))
                .frame(width: 6, height: 6)
            Text(step.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(future, color: Theme.secondary)
            Spacer(minLength: 4)
            Text(Self.time.string(from: step.date))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondary.opacity(future ? 0.6 : 1))
        }
        .font(.system(size: 12, weight: current ? .semibold : .regular))
        .foregroundStyle(future ? Theme.secondary.opacity(0.7) : Theme.text.opacity(current ? 1 : 0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(current ? Theme.panelRaised : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { store.jumpToStep(index) }
        .help(step.label)
        .contextMenu {
            Button("Go to this step") { store.jumpToStep(index) }
            if current && future == false && index < (store.current?.history.count ?? 0) - 1 {
                Button("Remove later steps") { store.trimHistoryAfterCurrent() }
            }
        }
    }
}
