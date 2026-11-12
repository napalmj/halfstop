import SwiftUI

/// Help ▸ Halfstop Help (⌘?): every shortcut and gesture, searchable, plus a few how-it-works notes.
/// Keep this in step with `KeyHandler` and `HalfstopCommands`.
struct HelpView: View {
    @State private var query = ""

    struct Item: Identifiable {
        let id = UUID()
        let keys: [String]
        let what: String
    }

    struct Section: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let items: [Item]
    }

    static let sections: [Section] = [
        Section(title: "Library", icon: "square.grid.2x2", items: [
            Item(keys: ["← → ↑ ↓"], what: "Move between photos"),
            Item(keys: ["⇧ click", "⌘ click"], what: "Select a range / add to the selection"),
            Item(keys: ["Return"], what: "Open the photo in the editor"),
            Item(keys: ["G"], what: "Library"),
            Item(keys: ["E"], what: "Edit"),
            Item(keys: ["B"], what: "Add the selection to the target collection"),
            Item(keys: ["Delete"], what: "In a collection: remove from it. Elsewhere: move to Trash (asks first)"),
            Item(keys: ["⇧⌘S"], what: "Show or hide the sidebar (history in the editor)"),
        ]),
        Section(title: "Rating & flags", icon: "star", items: [
            Item(keys: ["1 – 5"], what: "Rate (press the same number again to clear)"),
            Item(keys: ["0"], what: "Clear the rating"),
            Item(keys: ["P"], what: "Pick"),
            Item(keys: ["X"], what: "Reject"),
            Item(keys: ["U"], what: "Unflag"),
            Item(keys: ["⇧ with any of these"], what: "Rate or flag, then go to the next photo"),
            Item(keys: ["Photo ▸ Auto Advance After Rating"], what: "Always go to the next photo after rating or flagging"),
            Item(keys: ["Stars in the top bar"], what: "Rate and flag while editing"),
        ]),
        Section(title: "Deleting", icon: "trash", items: [
            Item(keys: ["⌘⌫"], what: "Move the selected photos to the Trash (asks first)"),
            Item(keys: ["Photo ▸ Delete Rejected Photos…"], what: "Trash every rejected photo in the current folder or collection"),
            Item(keys: ["Finder ▸ Put Back"], what: "Restore a trashed photo. Put back its matching .json files too to keep its edits and history"),
        ]),
        Section(title: "Editing", icon: "slider.horizontal.3", items: [
            Item(keys: ["\\"], what: "Before / after"),
            Item(keys: ["J"], what: "Show clipping: red = blown highlights, blue = crushed shadows"),
            Item(keys: ["W"], what: "Pick white balance: click something that should be gray"),
            Item(keys: ["Auto tone", "Auto WB"], what: "One-click starting points (top of the panel)"),
            Item(keys: ["Hover a slider + ↑ ↓"], what: "Nudge it (⇧ for bigger steps)"),
            Item(keys: ["Click a slider's value"], what: "Type an exact number"),
            Item(keys: ["D"], what: "Switch between Quick and Detailed panels"),
            Item(keys: ["C", "R"], what: "Crop & straighten"),
            Item(keys: ["Double-click a slider"], what: "Reset it"),
            Item(keys: ["Esc"], what: "Back out: crop → refine → mask → before/after → library"),
            Item(keys: ["⇧⌘C", "⇧⌘V"], what: "Copy / paste settings (to the whole selection)"),
            Item(keys: ["⌥⇧⌘V"], what: "Paste only some settings (light, color, masks, crop…)"),
            Item(keys: ["⇧⌘R"], what: "Reset all adjustments"),
        ]),
        Section(title: "History", icon: "clock.arrow.circlepath", items: [
            Item(keys: ["⌘Z", "⇧⌘Z"], what: "Undo / redo, one history step at a time"),
            Item(keys: ["Click a step"], what: "Go back to it. Your next edit removes the struck-out steps after it"),
            Item(keys: ["Snapshots ▸ Save"], what: "Keep a named version. Snapshots survive trimming and clearing"),
        ]),
        Section(title: "Masks", icon: "circle.lefthalf.filled", items: [
            Item(keys: ["O"], what: "Show or hide the red mask overlay"),
            Item(keys: ["[", "]"], what: "Smaller / bigger brush"),
            Item(keys: ["⌥ drag"], what: "Erase with the brush (or flip Add / Subtract when refining)"),
            Item(keys: ["⇧ drag"], what: "Add another linear or radial shape to the same mask"),
            Item(keys: ["Click a subject"], what: "Include or leave out that subject (subject masks)"),
            Item(keys: ["Drag a handle"], what: "Move, resize or feather the active shape"),
        ]),
        Section(title: "Files", icon: "folder", items: [
            Item(keys: ["⌘I"], what: "Import a folder (photos stay where they are)"),
            Item(keys: ["Drop a folder"], what: "Import it"),
            Item(keys: ["⌘S"], what: "Save now (edits also save on their own after a moment)"),
            Item(keys: ["⇧⌘E"], what: "Export"),
        ]),
    ]

    private static let notes: [(String, String)] = [
        ("Your files are never changed", "Edits, ratings and history live in a small .halfstop folder next to your photos. Export to get edited copies."),
        ("Deleting goes to the Trash", "Halfstop never erases files. Trashed photos come back with Finder's Put Back until you empty the Trash."),
        ("Each photo keeps its own crop", "Paste settings copies everything except the crop. Presets carry only the global look, never crop or masks."),
    ]

    private var filtered: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.sections }
        return Self.sections.compactMap { s in
            if s.title.lowercased().contains(q) { return s }
            let items = s.items.filter { i in i.what.lowercased().contains(q) || i.keys.contains { $0.lowercased().contains(q) } }
            return items.isEmpty ? nil : Section(title: s.title, icon: s.icon, items: items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Halfstop Help").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                    TextField("Search shortcuts", text: $query)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 7))
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                let sections = filtered
                if sections.isEmpty {
                    Text("No shortcuts match “\(query)”.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        .padding(40)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .top),
                                        GridItem(.flexible(), spacing: 18, alignment: .top)],
                              alignment: .leading, spacing: 18) {
                        ForEach(sections) { SectionCard(section: $0) }
                    }
                    .padding(22)
                }
                if query.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Self.notes, id: \.0) { note in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.0).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(note.1).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
    }

    private struct SectionCard: View {
        let section: Section

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Label(section.title.uppercased(), systemImage: section.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.text.opacity(0.8))
                    .padding(.bottom, 8)
                ForEach(section.items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        HStack(spacing: 4) {
                            ForEach(item.keys, id: \.self) { KeyCap(text: $0) }
                        }
                        .frame(width: 128, alignment: .leading)
                        Text(item.what)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private struct KeyCap: View {
        let text: String
        /// Short key names look like keys; longer ones ("Click a step") are plain labels.
        private var isKey: Bool { text.count <= 9 && !text.contains(" ▸ ") }

        var body: some View {
            Text(text)
                .font(.system(size: isKey ? 11.5 : 11, weight: isKey ? .medium : .regular,
                              design: isKey ? .rounded : .default))
                .foregroundStyle(isKey ? Theme.text : Theme.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, isKey ? 6 : 0)
                .padding(.vertical, isKey ? 2 : 0)
                .background {
                    if isKey {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.panelRaised)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))
                    }
                }
        }
    }
}
