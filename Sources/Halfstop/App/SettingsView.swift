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
            LocalControlSection()
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings ▸ Local AI control (MCP).
private struct LocalControlSection: View {
    @Environment(LocalControl.self) private var control
    @State private var copied: String?

    var body: some View {
        @Bindable var control = control
        Section("Local AI control (MCP)") {
            Toggle("Let AI apps on this Mac edit the open photo", isOn: $control.enabled)
            Text("Runs a local MCP server for an AI app you use on this Mac, such as Claude Code or Claude Desktop. It listens on 127.0.0.1 only (nothing on your network can reach it), needs the token below, and can only read and edit the photo open in the editor, one undoable step at a time. Halfstop itself sends nothing anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("Port") {
                TextField("Port", value: $control.port, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .help("\(LocalControl.portRange.lowerBound) to \(LocalControl.portRange.upperBound). The server restarts on the new port.")
            }
            LabeledContent("Token") {
                HStack(spacing: 8) {
                    if let token = control.token {
                        Text(LocalControl.masked(token)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        copyButton("Copy", token, id: "token")
                        Button("Regenerate") { control.regenerateToken() }
                            .help("Make a new token. AI apps set up with the old one stop working until you give them the new one.")
                    } else {
                        Text("Made when you turn this on").foregroundStyle(.secondary)
                    }
                }
            }
            if let token = control.token {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add it to your AI app")
                    Text("Claude Code: run the command in Terminal. Other apps: paste the JSON into their MCP server settings. Both include the token, so keep them private.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        copyButton("Copy command", control.addCommand(token: token), id: "command")
                        copyButton("Copy JSON config", control.configJSON(token: token), id: "json")
                    }
                    Text(control.configJSON(token: LocalControl.masked(token)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func copyButton(_ title: String, _ text: String, id: String) -> some View {
        Button(copied == id ? "Copied" : title) {
            control.copy(text)
            copied = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == id { copied = nil } }
        }
    }

    private var statusText: String {
        switch control.status {
        case .off: "Off"
        case .starting: "Starting…"
        case .running(let port): "Running on 127.0.0.1:\(String(port))"
        case .portInUse(let port): "Port \(String(port)) is in use by another app. Choose another port."
        case .failed(let why): why
        }
    }

    private var statusColor: Color {
        switch control.status {
        case .running: .green
        case .starting: .yellow
        case .off: .secondary
        case .portInUse, .failed: .red
        }
    }
}
