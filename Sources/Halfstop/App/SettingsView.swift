import SwiftUI

/// Halfstop ▸ Settings… (⌘,).
struct SettingsView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Auto") {
                Toggle("Learn from my edits", isOn: $store.learnFromEdits)
                Text("✦ Auto adapts to how you finish similar photos, once you have edited at least \(StyleModel.minimumSamples). It learns on this Mac, from your own edits only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
