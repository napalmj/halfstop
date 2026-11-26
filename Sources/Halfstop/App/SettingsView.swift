import SwiftUI
import AppKit

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
            CommandLineSection()
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings ▸ Command-line tool: how to put `halfstop` on the PATH. Nothing is installed for the user.
private struct CommandLineSection: View {
    @State private var copied = false

    var body: some View {
        Section("Command-line tool") {
            Text("The halfstop command lets you, or an AI agent with a shell such as Claude Code, read and edit photos from Terminal. It changes only Halfstop's own edit files, never the photos, and every change is an undoable step. To install it, run this in Terminal (no administrator rights needed), then try halfstop --help.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                Text(CommandLineTool.installCommand())
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(CommandLineTool.installCommand(), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
            }
        }
    }
}
