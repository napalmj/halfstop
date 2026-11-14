import Foundation
import CoreImage
import ImageIO
import Darwin

/// `halfstop <command> <photo>…`: read and edit photos from Terminal, or from an AI agent that can
/// run commands (Claude Code, say). It runs without a window or Dock icon, prints, and exits with
/// 0 (everything worked), 1 (a photo failed; the others were still done) or 2 (bad usage).
///
/// Edits go only to Halfstop's own sidecar files (`<folder>/.halfstop/`), through the same code and
/// formats as the app: one history step per photo per command, marked as made from the command line,
/// so the app can undo it. Photo files are only ever read. Each photo's files are read and rewritten
/// holding the folder's `SidecarLock`, so parallel runs and the app never lose each other's edits;
/// fields written by a newer Halfstop are kept (`UnknownFields`). The catalog is only read (for
/// "Learn from my edits"); the app owns it.
@MainActor
enum CommandLineTool {
    enum Command: String, CaseIterable {
        case info, get, set, auto, straighten, undo, redo, render, help
    }

    /// Whether the arguments ask for the command line tool rather than the app.
    nonisolated static func handles(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        return Command(rawValue: first) != nil || ["--help", "-h", "--version"].contains(first)
    }

    /// What the tool reads besides the photos (the self-test swaps them).
    struct Environment {
        /// The library index, read for "Learn from my edits"; never written.
        var catalogURL: URL? = CommandLineTool.defaultCatalogURL
        /// nil: the app's own setting (on unless switched off in Settings).
        var learnFromEdits: Bool?
        var engine: AutoEngine = .shared
    }

    nonisolated static var defaultCatalogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halfstop/catalog.json")
    }

    /// Runs the tool, printing to standard output and error.
    nonisolated static func main(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        return MainActor.assumeIsolated {
            run(args, environment: Environment(), out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
                err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        }
    }

    // MARK: Arguments

    struct Options {
        var command: Command
        var photos: [String] = []
        var changes: [EditFields.Change] = []
        var json = false
        var label: String?
        var output: String?
        var size = CommandLineTool.defaultRenderSize
        var force = false
    }

    nonisolated static let defaultRenderSize = 1024
    nonisolated static let renderSizes = 16...4096

    enum Parsed {
        case run(Options)
        case help(Command?)
        case version
        case usage(String, json: Bool)
    }

    static func parse(_ args: [String]) -> Parsed {
        guard let first = args.first else { return .help(nil) }
        if first == "--help" || first == "-h" { return .help(nil) }
        if first == "--version" { return .version }
        guard let command = Command(rawValue: first) else { return .usage("Unknown command “\(first)”. Run halfstop --help.", json: false) }
        let rest = Array(args.dropFirst())
        let json = rest.contains("--json")
        if command == .help {
            guard let topic = rest.first else { return .help(nil) }
            guard let c = Command(rawValue: topic), rest.count == 1 else { return .usage("halfstop help takes one command name, like halfstop help set.", json: false) }
            return .help(c)
        }
        var o = Options(command: command)
        var i = 0
        var onlyPhotos = false
        func value(_ name: String) -> String? {
            guard i + 1 < rest.count else { return nil }
            i += 1
            return rest[i]
        }
        while i < rest.count {
            let a = rest[i]
            defer { i += 1 }
            if onlyPhotos { o.photos.append(a); continue }
            switch a {
            case "--": onlyPhotos = true; continue
            case "--help", "-h": return .help(command)
            case "--json": o.json = true; continue
            default: break
            }
            if a.hasPrefix("-") && a.count > 1 {
                let (name, inline) = a.hasPrefix("--") && a.contains("=")
                    ? (String(a[..<a.firstIndex(of: "=")!]), String(a[a.index(after: a.firstIndex(of: "=")!)...]))
                    : (a, nil)
                switch (command, name) {
                case (.set, "--label"):
                    guard let v = inline ?? value(name) else { return .usage("--label needs a text, like --label \"Warmer\".", json: json) }
                    o.label = v
                case (.render, "-o"), (.render, "--output"):
                    guard let v = inline ?? value(name) else { return .usage("\(name) needs a file name ending in .jpg.", json: json) }
                    o.output = v
                case (.render, "--size"):
                    guard let v = inline ?? value(name), let n = Int(v), String(n) == v, renderSizes.contains(n) else {
                        return .usage("--size needs a whole number of pixels from \(renderSizes.lowerBound) to \(renderSizes.upperBound).", json: json)
                    }
                    o.size = n
                case (.render, "--force"):
                    o.force = true
                default:
                    return .usage("\(command.rawValue) doesn't take \(name). Run halfstop help \(command.rawValue).", json: json)
                }
                continue
            }
            if let change = EditFields.parseChange(a) {
                guard command == .set else {
                    return .usage("“\(a)” looks like a slider change; only halfstop set takes those. (A photo with a name like that goes after --.)", json: json)
                }
                switch change {
                case .success(let c): o.changes.append(c)
                case .failure(let e): return .usage(e.message, json: json)
                }
                continue
            }
            o.photos.append(a)
        }
        guard !o.photos.isEmpty else { return .usage("Give at least one photo. Run halfstop help \(command.rawValue).", json: json) }
        switch command {
        case .set:
            if let problem = EditFields.validate(o.changes) { return .usage(problem, json: json) }
        case .render:
            guard o.photos.count == 1 else { return .usage("render takes one photo at a time.", json: json) }
            guard o.output != nil else { return .usage("render needs -o <file.jpg> for the preview it writes.", json: json) }
        default:
            break
        }
        return .run(o)
    }

    // MARK: Running

    /// The whole tool, with output going to `out` (results) and `err` (problems). Returns the exit code.
    static func run(_ args: [String], environment: Environment, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        switch parse(args) {
        case .help(let c):
            out(c.map(CommandLineHelp.text(for:)) ?? CommandLineHelp.overview)
            return 0
        case .version:
            out("halfstop \(version)")
            return 0
        case .usage(let message, let json):
            if json {
                out(JSONValue.object(["ok": false, "error": .string(message), "command": .string(args.first ?? "")]).text)
            } else {
                err("halfstop: \(message)")
            }
            return 2
        case .run(let o):
            var session = Session(options: o, environment: environment)
            var results: [JSONValue] = []
            var failed = false
            var seen = Set<String>()
            for raw in o.photos {
                let outcome: Result<Report, CommandError>
                switch PhotoPath.check(raw) {
                case .failure(let e):
                    outcome = .failure(e)
                case .success(let url):
                    // The same photo twice (a shell glob plus a name, say) is done once.
                    guard seen.insert(LibraryFiles.canonical(url)).inserted else { continue }
                    outcome = session.perform(on: url)
                }
                switch outcome {
                case .success(let report):
                    if o.json { results.append(report.json.merging(["photo": .string(raw), "ok": true])) } else { out(report.text(raw)) }
                case .failure(let e):
                    failed = true
                    if o.json { results.append(["photo": .string(raw), "ok": false, "error": .string(e.message)]) } else { err("halfstop: \(raw): \(e.message)") }
                }
            }
            if o.json {
                out(JSONValue.object(["command": .string(o.command.rawValue), "ok": .bool(!failed), "results": .array(results)]).text)
            }
            return failed ? 1 : 0
        }
    }

    nonisolated static var version: String {
        appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(development build)"
    }

    /// The executable with links resolved (`halfstop` is usually a link to it in ~/.local/bin).
    nonisolated static var realExecutable: URL? {
        Bundle.main.executableURL.map { URL(fileURLWithPath: LibraryFiles.canonical($0)) }
    }

    /// Halfstop.app, also when started through a link (then `Bundle.main` is the link's folder,
    /// which has no Info.plist or resources).
    nonisolated static let appBundle: Bundle = {
        guard Bundle.main.bundleURL.pathExtension != "app", let exe = realExecutable else { return .main }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", exe.deletingLastPathComponent().lastPathComponent == "MacOS" else { return .main }
        return Bundle(url: app) ?? .main
    }()

    /// Started through a link to the app's executable, outside its bundle: the app itself can't
    /// run like that (it would have no settings or icon), only the commands.
    nonisolated static var startedThroughLink: Bool { appBundle !== Bundle.main }

    struct CommandError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// What one command did to one photo.
    struct Report {
        var json: [String: JSONValue]
        var lines: [String]
        func text(_ photo: String) -> String {
            guard let first = lines.first else { return photo }
            return (["\(photo): \(first)"] + lines.dropFirst().map { "  " + $0 }).joined(separator: "\n")
        }
    }

    // MARK: Install

    /// The Terminal command that puts `halfstop` on the PATH (a link in ~/.local/bin to this executable).
    nonisolated static func installCommand(executable: String? = nil) -> String {
        let exe = executable ?? realExecutable?.path ?? "/Applications/Halfstop.app/Contents/MacOS/Halfstop"
        return "mkdir -p ~/.local/bin && ln -sf \(shellQuoted(exe)) ~/.local/bin/halfstop"
    }

    nonisolated static func shellQuoted(_ s: String) -> String {
        let safe = s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "/._-+".unicodeScalars.contains($0) }
        return safe ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Photo paths

enum PhotoPath {
    /// The photo at `raw` (relative to the current folder), if it's a supported image file that
    /// can be read. Links are refused, as the library skips them too.
    static func check(_ raw: String) -> Result<URL, CommandLineTool.CommandError> {
        typealias E = CommandLineTool.CommandError
        guard !raw.isEmpty, !raw.contains("\0") else { return .failure(E("Empty photo path.")) }
        let url = URL(fileURLWithPath: raw).absoluteURL.standardizedFileURL
        switch LibraryFiles.kind(url) {
        case nil: return .failure(E("No such file."))
        case .link: return .failure(E("Is a link; give the photo file itself."))
        case .directory: return .failure(E("Is a folder; give photo files (a shell pattern like folder/*.jpg works)."))
        case .other: return .failure(E("Isn't a regular file."))
        case .file: break
        }
        let parts = url.pathComponents
        if parts.contains(SidecarFiles.folderName) || parts.contains(LegacyNames.sidecarFolder) {
            return .failure(E("Is one of Halfstop's own edit files, not a photo."))
        }
        let ext = url.pathExtension.lowercased()
        guard ImageFormats.all.contains(ext) else {
            return .failure(E("Isn't a supported photo type (\(ext.isEmpty ? "no extension" : "." + ext)). Supported: \(ImageFormats.all.sorted().joined(separator: ", "))."))
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .failure(E("Can't be read (permissions).")) }
        let readable: Bool
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetType(src) != nil, CGImageSourceGetCount(src) > 0 {
            readable = true
        } else {
            readable = ImageFormats.raw.contains(ext) && CIRAWFilter(imageURL: url) != nil
        }
        guard readable else { return .failure(E("Can't be read as an image.")) }
        return .success(url)
    }
}

// MARK: - Commands

extension CommandLineTool {
    /// One run of a command over its photos. Holds what's shared between photos (the learned model).
    @MainActor
    struct Session {
        let options: Options
        let environment: Environment
        /// Built on first use by ✦ Auto: nil when learning is off or there's nothing usable.
        private var learned: LearnedStyle??

        init(options: Options, environment: Environment) {
            self.options = options
            self.environment = environment
        }

        mutating func perform(on url: URL) -> Result<Report, CommandError> {
            do {
                switch options.command {
                case .info: return .success(try info(url, withAnalysis: true))
                case .get: return .success(try info(url, withAnalysis: false))
                case .set: return .success(try set(url))
                case .auto: return .success(try auto(url))
                case .straighten: return .success(try straighten(url))
                case .undo: return .success(try step(url, by: -1))
                case .redo: return .success(try step(url, by: 1))
                case .render: return .success(try render(url))
                case .help: throw CommandError("help isn't a photo command.")
                }
            } catch let e as CommandError {
                return .failure(e)
            } catch let e as SidecarFiles.Failure {
                return .failure(CommandError(e.localizedDescription))
            } catch let e as SidecarLock.Failure {
                return .failure(CommandError(e.localizedDescription))
            } catch {
                return .failure(CommandError("Couldn't save the edits: \(LibraryStore.describeSaveError(error))."))
            }
        }

        // MARK: Reading

        /// The photo's edits as saved, read holding the folder's lock (so never half written).
        func read(_ url: URL) throws -> Sidecar {
            try SidecarLock.with(url, exclusive: false, create: false) {
                var s = SidecarFiles.read(for: url) ?? Sidecar()
                s.ensureHistory()
                return s
            }
        }

        func info(_ url: URL, withAnalysis: Bool) throws -> Report {
            let s = try read(url)
            let a = s.adjustments
            var json: [String: JSONValue] = [
                "values": EditFields.values(a),
                "other_edits": EditFields.otherEdits(a),
                "history": historyJSON(s),
            ]
            var lines = ["sliders: \(EditFields.valuesText(a))", "other edits: \(EditFields.otherEditsText(a))", historyText(s)]
            guard withAnalysis else {
                lines[0] = lines[0].replacingOccurrences(of: "sliders: ", with: "")
                return Report(json: json, lines: lines)
            }
            let size = EditFields.pixelSize(url)
            let raw = ImageFormats.raw.contains(url.pathExtension.lowercased())
            json["file_name"] = .string(url.lastPathComponent)
            json["width"] = size.map { .int($0.0) } ?? .null
            json["height"] = size.map { .int($0.1) } ?? .null
            json["raw"] = .bool(raw)
            json["rating"] = .int(s.rating)
            json["flag"] = .string(s.flag.rawValue)
            let dims = size.map { "\($0.0) × \($0.1)" } ?? "unknown size"
            var head = ["\(dims), \(raw ? "RAW" : url.pathExtension.uppercased()), rating \(s.rating), flag \(s.flag.rawValue)"]
            // One small decode serves both measurements (the engine keeps it).
            let auto = environment.engine.resultNow(for: AutoRequest(url: url, kind: .auto, adjustments: a))
            let level = environment.engine.resultNow(for: AutoRequest(url: url, kind: .straighten, adjustments: a))
            if let auto {
                let insight = PhotoInsight(stats: auto.stats, scene: auto.scene, faces: auto.hints.faces,
                                           horizon: level?.horizon, straightenAngle: level?.angle)
                json["analysis"] = EditFields.insightJSON(insight)
                head.append(analysisText(insight))
            } else {
                json["analysis"] = .null
                head.append("analysis: the photo couldn't be decoded")
            }
            return Report(json: json, lines: head + lines)
        }

        func analysisText(_ i: PhotoInsight) -> String {
            var parts = ["scene \(i.scene?.rawValue ?? "unknown")", "faces \(i.faces.count)"]
            if let h = i.horizon {
                parts.append(String(format: "horizon %.1f° (confidence %.2f)", h.angle, h.confidence))
            } else {
                parts.append("no horizon")
            }
            parts.append(i.straightenAngle.map { String(format: "straighten would set %.1f°", $0) } ?? "straighten would do nothing")
            var line = "analysis: " + parts.joined(separator: ", ")
            if let st = i.stats {
                let p = [5, 25, 50, 75, 95].map { String(format: "p%d %.2f", $0, st.percentile(Double($0) / 100)) }.joined(separator: " ")
                line += String(format: "\n  luminance %@; mean chroma %.3f; skin %.2f", p, st.meanChroma, st.skinFraction)
            }
            return line
        }

        func historyJSON(_ s: Sidecar) -> JSONValue {
            [
                "steps": .int(s.history.count),
                "current_step": .int(s.historyIndex + 1),
                "current_label": .string(s.currentStep?.label ?? ""),
                "current_step_from_command_line": .bool(s.currentStep?.commandLine ?? false),
                "can_undo": .bool(s.historyIndex > 0),
                "can_redo": .bool(s.historyIndex < s.history.count - 1),
            ]
        }

        func historyText(_ s: Sidecar) -> String {
            "history: step \(s.historyIndex + 1) of \(s.history.count) “\(s.currentStep?.label ?? "")”"
                + (s.historyIndex < s.history.count - 1 ? " (\(s.history.count - 1 - s.historyIndex) to redo)" : "")
        }

        // MARK: Writing

        /// The edits in `disk`, to be changed and written back; nil when there are none yet. Throws
        /// when any part can't be read (damaged, or written by a newer Halfstop in a way this version
        /// can't decode), since rewriting the files would drop that part.
        func decodeForRewrite(_ disk: SidecarSnapshot, _ url: URL) throws -> Sidecar? {
            var incomplete = false
            let decoded = SidecarFiles.decode(disk, for: url, incomplete: &incomplete)
            if incomplete {
                throw CommandError("Part of its Halfstop edits can't be read by this version (damaged, or saved by a newer Halfstop), so it isn't changed (a copy was kept next to it).")
            }
            return decoded
        }

        /// Reads the photo's sidecar holding the lock, lets `change` turn its edits into new ones
        /// (nil: nothing to do), and if they differ, adds one history step and writes it back
        /// atomically, keeping fields this version doesn't know.
        func edit(_ url: URL, label: String, _ change: (Adjustments) throws -> Adjustments?) throws -> (before: Sidecar, after: Sidecar)? {
            try SidecarLock.with(url, exclusive: true, create: true) {
                let disk = SidecarFiles.snapshot(for: url)
                var s = try decodeForRewrite(disk, url) ?? Sidecar()
                s.ensureHistory()
                let before = s
                guard let next = try change(s.adjustments), next != s.adjustments else { return nil }
                var history = Array(s.history.prefix(s.historyIndex + 1))
                history.append(HistoryStep(label: label, adjustments: next, commandLine: true))
                if history.count > LibraryStore.historyLimit { history = [history[0]] + history.suffix(LibraryStore.historyLimit - 1) }
                s.history = history
                s.historyIndex = history.count - 1
                s.adjustments = next
                try SidecarFiles.write(s, for: url, history: true, keepingUnknownFrom: disk)
                return (before, s)
            }
        }

        func changeReport(_ before: Adjustments, _ after: Adjustments, label: String, extra: [String: JSONValue] = [:]) -> Report {
            let changes = EditFields.changes(from: before, to: after)
            var json = extra
            json["changed"] = true
            json["label"] = .string(label)
            json["changes"] = EditFields.changesJSON(changes)
            json["values"] = EditFields.values(after)
            return Report(json: json, lines: ["\(EditFields.describe(changes)) (one step “\(label)”)"])
        }

        func set(_ url: URL) throws -> Report {
            let label = options.label.map(EditFields.cleanLabel) ?? EditFields.defaultLabel
            var plan: EditFields.Plan?
            let done = try edit(url, label: label) { a in
                let p = EditFields.plan(options.changes, current: a)
                plan = p
                return p.adjustments
            }
            let clamped = plan?.clamped ?? []
            var extra: [String: JSONValue] = ["clamped": .array(clamped.map { .string($0) })]
            let note = clamped.isEmpty ? nil : "clamped to the slider range: \(clamped.joined(separator: ", "))"
            guard let done else {
                let current = plan?.adjustments ?? Adjustments()
                extra["changed"] = false
                extra["values"] = EditFields.values(current)
                return Report(json: extra, lines: ["no change: the sliders already have those values"] + (note.map { [$0] } ?? []))
            }
            var r = changeReport(done.before.adjustments, done.after.adjustments, label: label, extra: extra)
            if let note { r.lines.append(note) }
            return r
        }

        mutating func auto(_ url: URL) throws -> Report {
            let isRAW = ImageFormats.raw.contains(url.pathExtension.lowercased())
            // Measured outside the lock (it decodes the photo). If the crop changed meanwhile, measure again.
            for _ in 0..<3 {
                let start = try read(url).adjustments
                let request = AutoRequest(url: url, kind: .auto, adjustments: start)
                guard var result = environment.engine.resultNow(for: request) else { throw CommandError("The photo couldn't be decoded.") }
                result.learned = learnedOffset(for: url, result: result, isRAW: isRAW)
                var stale = false
                let done = try edit(url, label: AutoKind.auto.label) { a in
                    guard AutoRequest(url: url, kind: .auto, adjustments: a) == request else { stale = true; return nil }
                    return result.applied(to: a)
                }
                if stale { continue }
                let adapted: JSONValue = .bool(result.learned != nil)
                guard let done else {
                    return Report(json: ["changed": false, "adapted_to_user_edits": adapted, "values": EditFields.values(start)],
                                  lines: ["no change: ✦ Auto found nothing to change"])
                }
                var r = changeReport(done.before.adjustments, done.after.adjustments, label: AutoKind.auto.label, extra: ["adapted_to_user_edits": adapted])
                if result.learned != nil { r.lines.append("adapted to your own edits (Learn from my edits)") }
                return r
            }
            throw CommandError("The photo's crop kept changing while ✦ Auto measured it; try again.")
        }

        func straighten(_ url: URL) throws -> Report {
            let start = try read(url).adjustments
            guard let result = environment.engine.resultNow(for: AutoRequest(url: url, kind: .straighten, adjustments: start)) else {
                throw CommandError("The photo couldn't be decoded.")
            }
            let horizon: JSONValue = result.horizon.map { ["angle_degrees": .number($0.angle, places: 2), "confidence": .number($0.confidence, places: 2)] } ?? .null
            guard result.angle != nil else {
                return Report(json: ["changed": false, "reason": "no_horizon", "horizon": horizon, "values": EditFields.values(start)],
                              lines: ["No horizon found; nothing changed"])
            }
            // The angle doesn't depend on the edits, so whatever they are now, it applies.
            guard let done = try edit(url, label: AutoKind.straighten.label, { result.applied(to: $0) }) else {
                return Report(json: ["changed": false, "reason": "already_level", "horizon": horizon, "values": EditFields.values(start)],
                              lines: ["Horizon already level; nothing changed"])
            }
            return changeReport(done.before.adjustments, done.after.adjustments, label: AutoKind.straighten.label, extra: ["horizon": horizon])
        }

        /// Undo (-1) or redo (+1): moves within the history, like the app's ⌘Z / ⇧⌘Z.
        func step(_ url: URL, by delta: Int) throws -> Report {
            try SidecarLock.with(url, exclusive: true, create: false) {
                let disk = SidecarFiles.snapshot(for: url)
                guard var s = try decodeForRewrite(disk, url) else {
                    return Report(json: ["changed": false, "reason": "no_history"], lines: [delta < 0 ? "nothing to undo" : "nothing to redo"])
                }
                s.ensureHistory()
                let target = s.historyIndex + delta
                guard s.history.indices.contains(target) else {
                    return Report(json: ["changed": false, "reason": delta < 0 ? "at_start" : "at_end", "history": historyJSON(s), "values": EditFields.values(s.adjustments)],
                                  lines: [delta < 0 ? "nothing to undo" : "nothing to redo"])
                }
                let before = s.adjustments
                // Undo names the step it takes back; redo the step it brings back.
                let stepLabel = (delta < 0 ? s.history[s.historyIndex] : s.history[target]).label
                s.historyIndex = target
                s.adjustments = s.history[target].adjustments
                try SidecarFiles.write(s, for: url, history: true, keepingUnknownFrom: disk)
                let changes = EditFields.changes(from: before, to: s.adjustments)
                let verb = delta < 0 ? "undid" : "redid"
                var lines = ["\(verb) “\(stepLabel)”" + (changes.isEmpty ? "" : ": \(EditFields.describe(changes))")]
                lines.append(historyText(s))
                return Report(json: ["changed": true, delta < 0 ? "undone_step" : "redone_step": .string(stepLabel),
                                     "changes": EditFields.changesJSON(changes), "values": EditFields.values(s.adjustments), "history": historyJSON(s)],
                              lines: lines)
            }
        }

        // MARK: Render

        func render(_ url: URL) throws -> Report {
            guard let output = options.output else { throw CommandError("render needs -o <file.jpg>.") }
            let dest = URL(fileURLWithPath: output).absoluteURL.standardizedFileURL
            if let problem = RenderTarget.problem(dest, source: url, force: options.force) { throw CommandError(problem) }
            let a = try read(url).adjustments
            let size = options.size
            // Decode about as large as the crop needs for `size` pixels, never the full photo when smaller will do.
            let span = max(0.05, max(a.crop.rect.width, a.crop.rect.height))
            let decode = min(8192, (Double(size) / span * (a.crop.angle == 0 ? 1 : 1.42)).rounded(.up))
            guard let source = ImageSource(url: url, maxPixelSize: CGFloat(decode)) else { throw CommandError("The photo couldn't be decoded.") }
            let image = source.developed(a, exporting: true)
            guard !image.extent.isEmpty, !image.extent.isInfinite,
                  let cg = Render.background.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: Render.sRGB),
                  let jpeg = EditFields.jpeg(cg, maxSize: size) else { throw CommandError("The photo couldn't be rendered.") }
            try RenderTarget.write(jpeg.data, to: dest, replace: options.force)
            return Report(json: ["output": .string(output), "width": .int(jpeg.width), "height": .int(jpeg.height), "bytes": .int(jpeg.data.count)],
                          lines: ["wrote \(output) (\(jpeg.width) × \(jpeg.height) JPEG of the current edit, no metadata)"])
        }

        // MARK: Learn from my edits

        mutating func learnedOffset(for url: URL, result: AutoResult, isRAW: Bool) -> StyleOffset? {
            if learned == nil { learned = .some(LearnedStyle.load(environment)) }
            guard let model = learned ?? nil, let features = StyleFeatures.make(result, isRAW: isRAW) else { return nil }
            return model.model.predict(features, excluding: model.key(for: url))
        }
    }
}

// MARK: - Learn from my edits, read-only

/// The app's "Learn from my edits" model, rebuilt read-only from the catalog's samples and the
/// edited photos' sidecars, exactly as the app does (photos whose current step was made from the
/// command line don't count). nil when learning is off or there aren't enough edited photos.
struct LearnedStyle {
    let model: StyleModel
    let folders: [(path: String, id: UUID)]

    @MainActor
    static func load(_ env: CommandLineTool.Environment) -> LearnedStyle? {
        let enabled = env.learnFromEdits ?? {
            let v = CFPreferencesCopyAppValue(LibraryStore.learnFromEditsKey as CFString, "dev.halfstop.app" as CFString)
            return (v as? Bool) ?? true
        }()
        guard enabled, let catalogURL = env.catalogURL, let data = try? Data(contentsOf: catalogURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let catalog = try? decoder.decode(Catalog.self, from: data), catalog.styleSamples.count >= StyleModel.minimumSamples else { return nil }
        let folderByID = Dictionary(catalog.folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let samples = Array(catalog.styleSamples)
        // Each sample's photo: its current edits, read in parallel (only the edited photos have samples).
        let edits = SampleEdits(count: samples.count)
        DispatchQueue.concurrentPerform(iterations: samples.count) { i in
            let key = samples[i].key
            guard let slash = key.firstIndex(of: "/"), let id = UUID(uuidString: String(key[..<slash])),
                  let folder = folderByID[id] else { return }
            let rel = String(key[key.index(after: slash)...])
            let photo = URL(fileURLWithPath: folder.path).appendingPathComponent(rel)
            guard LibraryFiles.isInside(photo, LibraryFiles.canonical(folder.url)),
                  var s = try? SidecarLock.with(photo, exclusive: false, create: false, { SidecarFiles.read(for: photo) }) ?? nil else { return }
            s.ensureHistory()
            if s.currentStep?.commandLine == true { return }
            edits.set(i, s.adjustments)
        }
        var model = StyleModel()
        for (i, (key, sample)) in samples.enumerated() {
            if let a = edits.get(i) { model.update(key, sample: sample, adjustments: a) }
        }
        guard model.isActive else { return nil }
        return LearnedStyle(model: model, folders: catalog.folders.map { ($0.path, $0.id) })
    }

    /// The photo's key in the catalog (so its own edit never feeds its prediction).
    func key(for url: URL) -> String? {
        let path = LibraryFiles.canonical(url)
        for f in folders where path.hasPrefix(f.path + "/") {
            return PhotoRef(folder: f.id, path: String(path.dropFirst(f.path.count + 1))).key
        }
        return nil
    }

    private final class SampleEdits: @unchecked Sendable {
        private var items: [Adjustments?]
        private let lock = NSLock()
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ a: Adjustments) { lock.lock(); items[i] = a; lock.unlock() }
        func get(_ i: Int) -> Adjustments? { lock.lock(); defer { lock.unlock() }; return items[i] }
    }
}

// MARK: - Where render may write

enum RenderTarget {
    /// Why `dest` can't be written, or nil. Never the photo itself, never anything in an edits
    /// folder, a photo with Halfstop edits or a file with camera data, never a link or folder, and
    /// an existing file only with `force`.
    static func problem(_ dest: URL, source: URL, force: Bool) -> String? {
        let ext = dest.pathExtension.lowercased()
        guard ext == "jpg" || ext == "jpeg" else { return "The output must be a .jpg file." }
        let parent = dest.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            return "The folder \(parent.path) doesn't exist."
        }
        let canonicalParent = LibraryFiles.canonical(parent)
        let parts = URL(fileURLWithPath: canonicalParent).pathComponents
        if parts.contains(SidecarFiles.folderName) || parts.contains(LegacyNames.sidecarFolder) {
            return "That's inside Halfstop's edits folder; choose another place."
        }
        let target = canonicalParent + "/" + dest.lastPathComponent
        if target == LibraryFiles.canonical(source) || target.lowercased() == LibraryFiles.canonical(source).lowercased() {
            return "That's the photo itself; Halfstop never writes over photos."
        }
        switch LibraryFiles.kind(dest) {
        case nil:
            return nil
        case .link:
            return "\(dest.lastPathComponent) is a link; choose another name."
        case .directory, .other:
            return "\(dest.lastPathComponent) isn't a regular file."
        case .file:
            if sameFile(dest, source) { return "That's the photo itself; Halfstop never writes over photos." }
            guard force else { return "\(dest.lastPathComponent) already exists; add --force to replace it." }
            if LibraryFiles.kind(SidecarFiles.mainURL(for: dest)) != nil {
                return "\(dest.lastPathComponent) is a photo with Halfstop edits; it's never replaced."
            }
            if hasPhotoMetadata(dest) {
                return "\(dest.lastPathComponent) is a photo (it has camera data); it's never replaced. Choose another name."
            }
            return nil
        }
    }

    /// Whether the image at `url` carries photo metadata (Exif, TIFF, GPS or IPTC). Previews written
    /// by `render` have none, so `--force` can replace them, but never a photo from a camera or phone.
    static func hasPhotoMetadata(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary]
            .contains { props[$0] != nil }
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// Writes atomically: a temporary file next to it, renamed into place (refused if a file
    /// appeared there meanwhile, unless `replace`).
    static func write(_ data: Data, to dest: URL, replace: Bool) throws {
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).halfstop-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .withoutOverwriting)
        let flags = replace ? 0 : UInt32(RENAME_EXCL)
        if renamex_np(tmp.path, dest.path, flags) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            if code == EEXIST { throw CommandLineTool.CommandError("\(dest.lastPathComponent) already exists; add --force to replace it.") }
            throw CommandLineTool.CommandError("Couldn't write \(dest.lastPathComponent): \(String(cString: strerror(code))).")
        }
    }
}

extension JSONValue {
    /// This object with `other`'s keys added (or replaced).
    func merging(_ other: [String: JSONValue]) -> JSONValue {
        guard case .object(var o) = self else { return self }
        for (k, v) in other { o[k] = v }
        return .object(o)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func merging(_ other: [String: JSONValue]) -> JSONValue { JSONValue.object(self).merging(other) }
}
