import Foundation
import ImageIO
import CoreGraphics

// MARK: - The halfstop command

extension LibraryTest {
    /// The command-line tool, in-process against temp photos: arguments, every command, sidecar
    /// round-trips, history steps, render safety, batches, locking, and the read-only learned model.
    @MainActor
    static func commandLineChecks(dir: URL, check: (String, Bool, String) -> Void) async {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func photo(_ name: String, hue: Double, variant: Int) -> URL {
            let url = dir.appendingPathComponent(name)
            if let img = SelfTest.scene(width: 600, height: 400, hue: hue, variant: variant) { SelfTest.write(img, to: url) }
            return url
        }
        let a = photo("a.jpg", hue: 0.1, variant: 1), b = photo("b.jpg", hue: 0.4, variant: 2), c = photo("c.jpg", hue: 0.7, variant: 3)
        let d = photo("d.jpg", hue: 0.55, variant: 4), e = photo("e.jpg", hue: 0.85, variant: 5)
        try? "not a photo".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try? Data("garbage".utf8).write(to: dir.appendingPathComponent("broken.jpg"))
        try? fm.createSymbolicLink(at: dir.appendingPathComponent("link.jpg"), withDestinationURL: a)
        let photos = [a, b, c, d, e]
        func digest(_ u: URL) -> UInt64 { (try? Data(contentsOf: u)).map(SidecarFiles.hashForTests) ?? 0 }
        let originals = photos.map(digest)

        let env = CommandLineTool.Environment(catalogURL: nil, learnFromEdits: false, engine: AutoEngine())
        let cwd = fm.currentDirectoryPath
        fm.changeCurrentDirectoryPath(dir.path)
        defer { fm.changeCurrentDirectoryPath(cwd) }
        func run(_ args: [String]) -> (code: Int32, out: String, err: String) {
            var out: [String] = [], err: [String] = []
            let code = CommandLineTool.run(args, environment: env, out: { out.append($0) }, err: { err.append($0) })
            return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
        }
        func json(_ args: [String]) -> (Int32, JSONValue?) {
            let r = run(args + ["--json"])
            return (r.code, try? JSONValue.parse(Data(r.out.utf8)).get())
        }
        func sidecar(_ u: URL) -> Sidecar {
            var s = SidecarFiles.read(for: u) ?? Sidecar()
            s.ensureHistory()
            return s
        }

        // Arguments
        check("cli: subcommands are recognized, app flags are not",
              CommandLineTool.handles(["set"]) && CommandLineTool.handles(["--help"]) && !CommandLineTool.handles([])
              && !CommandLineTool.handles(["--selftest", "/tmp/x"]) && !CommandLineTool.handles(["-NSDocumentRevisionsDebugMode"]), "")
        if case .run(let o) = CommandLineTool.parse(["set", "a.jpg", "exposure=0.5", "contrast+=10", "shadows-=5", "--label", "Hi", "--", "exposure=1.jpg"]) {
            check("cli: set arguments parse", o.photos == ["a.jpg", "exposure=1.jpg"] && o.label == "Hi"
                  && o.changes == [.init(name: "exposure", kind: .set, value: 0.5), .init(name: "contrast", kind: .add, value: 10),
                                   .init(name: "shadows", kind: .add, value: -5)], "\(o.photos) \(o.changes)")
        } else {
            check("cli: set arguments parse", false, "")
        }
        let badNumbers = ["exposure=abc", "exposure=nan", "exposure=inf", "exposure=-inf", "exposure=1e999", "exposure=0x10", "exposure= 1",
                          "exposure=", "exposure=1.2.3", "exposure=+", "exposure=1e", "exposure=١"]
        let badCodes = badNumbers.map { run(["set", "a.jpg", $0]).code }
        check("cli: malformed numbers refused (exit 2)", badCodes.allSatisfy { $0 == 2 }, "\(zip(badNumbers, badCodes).filter { $0.1 != 2 })")
        let usage: [[String]] = [
            ["set", "a.jpg", "bogus=1"], ["set", "a.jpg", "exposure=1", "exposure=2"], ["set", "a.jpg"], ["set", "exposure=1"],
            ["set", "a.jpg", "Exposure=1"], ["get", "a.jpg", "exposure=1"], ["get", "a.jpg", "--frobnicate"], ["get"],
            ["render", "a.jpg"], ["render", "a.jpg", "b.jpg", "-o", "x.jpg"], ["render", "a.jpg", "-o", "x.jpg", "--size", "99999"],
            ["render", "a.jpg", "-o", "x.jpg", "--size", "1.5"], ["set", "a.jpg", "exposure=1", "--label"], ["frobnicate", "a.jpg"],
            ["auto", "a.jpg", "--label", "x"], ["help", "nope"],
        ]
        let usageCodes = usage.map { run($0).code }
        check("cli: bad usage exits 2 and changes nothing", usageCodes.allSatisfy { $0 == 2 } && !fm.fileExists(atPath: dir.appendingPathComponent(".halfstop").path),
              "\(zip(usage.map { $0.joined(separator: " ") }, usageCodes).filter { $0.1 != 2 })")
        let help = run(["--help"]), helpSet = run(["help", "set"])
        check("cli: help lists every command and slider with its range", help.code == 0 && helpSet.code == 0
              && CommandLineTool.Command.allCases.allSatisfy { help.out.contains($0.rawValue) }
              && EditFields.fields.allSatisfy { help.out.contains($0.name) && helpSet.out.contains($0.name) }
              && help.out.contains("-5 to 5") && help.out.contains("never changed") && help.out.contains("undo"), "")
        let usageJSON = json(["set", "a.jpg", "bogus=1"])
        check("cli: usage errors in JSON too", usageJSON.0 == 2 && usageJSON.1?["ok"] == false && usageJSON.1?["error"]?.stringValue != nil, "")

        // set: absolute, relative, clamping, rounding, one step
        let r1 = run(["set", "a.jpg", "exposure=0.5", "contrast=10"])
        var s = sidecar(a)
        check("cli: set writes one labelled step", r1.code == 0 && s.adjustments.exposure == 0.5 && s.adjustments.contrast == 10
              && s.history.count == 2 && s.historyIndex == 1 && s.currentStep?.label == EditFields.defaultLabel
              && s.currentStep?.commandLine == true && s.history[0].label == "Original", r1.out + r1.err)
        _ = run(["set", "a.jpg", "exposure+=0.25", "contrast-=30"])
        s = sidecar(a)
        check("cli: deltas", s.adjustments.exposure == 0.75 && s.adjustments.contrast == -20 && s.history.count == 3, "\(s.adjustments.exposure) \(s.adjustments.contrast)")
        let (clampCode, clamp) = json(["set", "a.jpg", "exposure=9", "sharpening=-5", "vibrance=12.6", "temperature-=500"])
        s = sidecar(a)
        let clampedList = clamp?["results"]?.arrayValue?.first?["clamped"]?.arrayValue?.compactMap(\.stringValue) ?? []
        check("cli: clamped to the slider ranges and reported", clampCode == 0 && s.adjustments.exposure == 5 && s.adjustments.sharpening == 0
              && s.adjustments.vibrance == 13 && s.adjustments.temperature == -100
              && Set(clampedList) == ["exposure", "sharpening", "temperature"], "\(clampedList)")
        let before = s.history.count
        let (sameCode, same) = json(["set", "a.jpg", "exposure=5"])
        check("cli: no change, no step", sameCode == 0 && sidecar(a).history.count == before
              && same?["results"]?.arrayValue?.first?["changed"] == false, "")
        _ = run(["set", "a.jpg", "exposure=0.123", "--label", "Warm\ner\t\u{202E}look  " + String(repeating: "x", count: 80)])
        s = sidecar(a)
        let label = s.currentStep?.label ?? ""
        check("cli: values rounded, label cleaned", s.adjustments.exposure == 0.12 && label.hasPrefix("Warm er look x")
              && label.count == EditFields.maxLabelLength && !label.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }, label)

        // Batch, with bad files in between
        let bBefore = sidecar(b).history.count
        let (batchCode, batch) = json(["set", "b.jpg", "missing.jpg", "notes.txt", "broken.jpg", "link.jpg", ".halfstop/a.jpg.json", "c.jpg", "b.jpg", "exposure=0.2"])
        let results = batch?["results"]?.arrayValue ?? []
        check("cli: batch goes on past bad files (exit 1)", batchCode == 1 && results.count == 7
              && results.map { $0["ok"]?.boolValue ?? false } == [true, false, false, false, false, false, true]
              && sidecar(b).adjustments.exposure == 0.2 && sidecar(c).adjustments.exposure == 0.2,
              results.map { "\($0["photo"]?.stringValue ?? ""): \($0["error"]?.stringValue ?? "ok")" }.joined(separator: "; "))
        check("cli: one step per photo per command (a repeated photo counts once)", sidecar(b).history.count == bBefore + 1, "\(sidecar(b).history.count)")
        check("cli: JSON output is stable", batch?["command"] == "set" && batch?["ok"] == false
              && results.first?["values"]?["exposure"] == .double(0.2) && results.first?["changes"]?["exposure"]?["to"] == .double(0.2), "")

        // get / info
        let (getCode, got) = json(["get", "b.jpg"])
        check("cli: get", getCode == 0 && got?["results"]?.arrayValue?.first?["values"]?["exposure"] == .double(0.2)
              && got?["results"]?.arrayValue?.first?["history"]?["current_step_from_command_line"] == true, "")
        // The tool sees the photo by its absolute path from the current folder (/private/tmp, not /tmp).
        let dSeen = URL(fileURLWithPath: "d.jpg").absoluteURL.standardizedFileURL
        AutoVision.shared.install(faces: [CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)], for: dSeen)
        AutoVision.shared.install(horizon: AutoVision.Horizon(angle: 3.2, confidence: 0.9), for: dSeen)
        let (infoCode, info) = json(["info", "d.jpg"])
        let first = info?["results"]?.arrayValue?.first
        check("cli: info", infoCode == 0 && first?["width"] == 600 && first?["height"] == 400 && first?["raw"] == false
              && first?["analysis"]?["luminance_percentiles"]?["p50"]?.numberValue != nil && first?["analysis"]?["faces"]?.arrayValue?.count == 1
              && first?["analysis"]?["auto_straighten_would_set_degrees"] == .double(3.2), first?.text ?? "")
        let infoText = run(["info", "c.jpg"])
        check("cli: info text", infoText.code == 0 && infoText.out.contains("600 × 400") && infoText.out.contains("analysis: scene"), infoText.out)

        // auto / straighten
        let (autoCode, auto) = json(["auto", "e.jpg"])
        let expected = env.engine.resultNow(for: AutoRequest(url: e, kind: .auto, adjustments: Adjustments()))?.applied(to: Adjustments())
        s = sidecar(e)
        check("cli: auto is the app's ✦ Auto, one step", autoCode == 0 && expected != nil && s.adjustments == expected
              && s.currentStep?.label == "Auto" && s.currentStep?.commandLine == true && s.history.count == 2
              && auto?["results"]?.arrayValue?.first?["adapted_to_user_edits"] == false, auto?.text ?? "")
        let straight = run(["straighten", "d.jpg"])
        check("cli: straighten with a horizon", straight.code == 0 && sidecar(d).adjustments.crop.angle == 3.2
              && sidecar(d).currentStep?.label == "Auto straighten", straight.out + straight.err)
        let cBefore = sidecar(c)
        let level = run(["straighten", "c.jpg"])
        check("cli: no horizon, no change", level.code == 0 && level.out.contains("No horizon found")
              && sidecar(c).history.count == cBefore.history.count && sidecar(c).adjustments == cBefore.adjustments, level.out)
        AutoVision.shared.removeOverrides(for: dSeen)

        // undo / redo
        let aSteps = sidecar(a)
        let undo = run(["undo", "a.jpg"])
        s = sidecar(a)
        check("cli: undo steps back", undo.code == 0 && s.historyIndex == aSteps.historyIndex - 1 && s.history.count == aSteps.history.count
              && s.adjustments == aSteps.history[aSteps.historyIndex - 1].adjustments && undo.out.contains("undid"), undo.out)
        _ = run(["redo", "a.jpg"])
        check("cli: redo steps forward", sidecar(a).historyIndex == aSteps.historyIndex && sidecar(a).adjustments == aSteps.adjustments, "")
        for _ in 0..<10 { _ = run(["undo", "a.jpg"]) }
        let (startCode, atStart) = json(["undo", "a.jpg"])
        check("cli: undo at the start does nothing", startCode == 0 && sidecar(a).historyIndex == 0 && sidecar(a).adjustments.isDefault
              && atStart?["results"]?.arrayValue?.first?["changed"] == false, "")
        _ = run(["set", "a.jpg", "tint=7"])
        check("cli: an edit after undo trims the redo steps", sidecar(a).history.count == 2 && sidecar(a).adjustments.tint == 7, "\(sidecar(a).history.count)")

        // Fields from a newer version survive; known ones aren't resurrected.
        let future = dir.appendingPathComponent("future.jpg")
        try? fm.copyItem(at: b, to: future)
        try? fm.createDirectory(at: dir.appendingPathComponent(".halfstop"), withIntermediateDirectories: true)
        var withMask = Adjustments()
        var mask = Mask(name: "Radial", kind: .radial)
        mask.subjects = [1, 2]
        withMask.masks = [mask]
        withMask.exposure = 0.3
        var seed = Sidecar()
        seed.adjustments = withMask
        seed.history = [HistoryStep(label: "Original", adjustments: Adjustments()), HistoryStep(label: "Mask", adjustments: withMask)]
        seed.historyIndex = 1
        _ = try? SidecarFiles.write(seed, for: future, history: true)
        func patch(_ url: URL, _ edit: (inout [String: Any]) -> Void) {
            guard let data = try? Data(contentsOf: url), var o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            edit(&o)
            try? JSONSerialization.data(withJSONObject: o).write(to: url)
        }
        patch(SidecarFiles.mainURL(for: future)) { o in
            o["futureTopLevel"] = ["x": 1]
            var adj = o["adjustments"] as? [String: Any] ?? [:]
            adj["futureSlider"] = 42
            var masks = adj["masks"] as? [[String: Any]] ?? []
            if !masks.isEmpty { masks[0]["futureMaskField"] = "keep" }
            adj["masks"] = masks
            o["adjustments"] = adj
        }
        patch(SidecarFiles.historyURL(for: future)) { o in
            o["futureHistoryField"] = true
            var steps = o["steps"] as? [[String: Any]] ?? []
            if steps.count > 1 { steps[1]["futureStepField"] = "keep" }
            o["steps"] = steps
        }
        _ = run(["set", "future.jpg", "exposure=0.9"])
        func raw(_ url: URL) -> [String: Any] {
            ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        }
        let mainRaw = raw(SidecarFiles.mainURL(for: future)), histRaw = raw(SidecarFiles.historyURL(for: future))
        let adjRaw = mainRaw["adjustments"] as? [String: Any] ?? [:]
        let maskRaw = (adjRaw["masks"] as? [[String: Any]])?.first ?? [:]
        let stepsRaw = histRaw["steps"] as? [[String: Any]] ?? []
        check("cli: fields it doesn't know survive a round trip", (mainRaw["futureTopLevel"] as? [String: Any])?["x"] as? Int == 1
              && adjRaw["futureSlider"] as? Int == 42 && maskRaw["futureMaskField"] as? String == "keep"
              && histRaw["futureHistoryField"] as? Bool == true && stepsRaw.count == 3 && stepsRaw[1]["futureStepField"] as? String == "keep"
              && (adjRaw["exposure"] as? Double) == 0.9 && sidecar(future).adjustments.masks.first?.subjects == [1, 2], "\(mainRaw.keys.sorted())")
        _ = run(["undo", "future.jpg"])
        _ = run(["undo", "future.jpg"])
        let undoneRaw = raw(SidecarFiles.mainURL(for: future))["adjustments"] as? [String: Any] ?? [:]
        check("cli: known fields aren't brought back (undo to no masks)", (undoneRaw["masks"] as? [Any])?.isEmpty == true
              && sidecar(future).adjustments.masks.isEmpty, "\(undoneRaw["masks"] ?? "none")")
        // An older sidecar with its history inline moves it out, without bringing it back into the main file.
        let legacy = dir.appendingPathComponent("legacy.jpg")
        try? fm.copyItem(at: b, to: legacy)
        var old = Sidecar()
        old.adjustments.exposure = 0.4
        old.history = [HistoryStep(label: "Original", adjustments: Adjustments()), HistoryStep(label: "Exposure +0.40", adjustments: old.adjustments)]
        old.historyIndex = 1
        try? JSONEncoder().encode(old).write(to: SidecarFiles.mainURL(for: legacy))
        _ = run(["set", "legacy.jpg", "contrast=5"])
        let legacyMain = raw(SidecarFiles.mainURL(for: legacy))
        check("cli: inline history moves to its own file", legacyMain["history"] == nil && legacyMain["historyIndex"] == nil
              && sidecar(legacy).history.count == 3 && sidecar(legacy).adjustments.exposure == 0.4, "\(legacyMain.keys.sorted())")
        let unreadable = dir.appendingPathComponent("unreadable.jpg")
        try? fm.copyItem(at: b, to: unreadable)
        try? Data("{not json".utf8).write(to: SidecarFiles.mainURL(for: unreadable))
        let refuse = run(["set", "unreadable.jpg", "exposure=1"])
        check("cli: an unreadable sidecar is left alone", refuse.code == 1
              && (try? Data(contentsOf: SidecarFiles.mainURL(for: unreadable))) == Data("{not json".utf8), refuse.err)
        // A mask of a kind this version doesn't know (a newer Halfstop): rewriting would drop it.
        let newerKind = dir.appendingPathComponent("newerkind.jpg")
        try? fm.copyItem(at: b, to: newerKind)
        var masked = Sidecar()
        masked.adjustments.masks = [Mask(name: "Radial", kind: .radial)]
        _ = try? SidecarFiles.write(masked, for: newerKind, history: true)
        patch(SidecarFiles.mainURL(for: newerKind)) { o in
            var adj = o["adjustments"] as? [String: Any] ?? [:]
            var masks = adj["masks"] as? [[String: Any]] ?? []
            if !masks.isEmpty { masks[0]["kind"] = "someFutureKind" }
            adj["masks"] = masks
            o["adjustments"] = adj
        }
        let newerBytes = try? Data(contentsOf: SidecarFiles.mainURL(for: newerKind))
        let refuseNewer = run(["set", "newerkind.jpg", "exposure=1"])
        check("cli: a sidecar with parts it can't read is left alone", refuseNewer.code == 1 && newerBytes != nil
              && (try? Data(contentsOf: SidecarFiles.mainURL(for: newerKind))) == newerBytes, refuseNewer.err)

        // render
        let out = dir.appendingPathComponent("previews", isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let (renderCode, rendered) = json(["render", "b.jpg", "-o", "previews/b.jpg", "--size", "300"])
        let props = CGImageSourceCreateWithURL(out.appendingPathComponent("b.jpg") as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        check("cli: render writes a small JPEG", renderCode == 0 && max(w, h) == 300 && rendered?["results"]?.arrayValue?.first?["width"] == .int(w), "\(w)×\(h)")
        check("cli: render strips metadata", props[kCGImagePropertyExifDictionary] == nil && props[kCGImagePropertyGPSDictionary] == nil
              && props[kCGImagePropertyTIFFDictionary] == nil && props[kCGImagePropertyIPTCDictionary] == nil, "\(props.keys)")
        try? fm.createSymbolicLink(at: out.appendingPathComponent("link.jpg"), withDestinationURL: dir.appendingPathComponent("victim.jpg"))
        try? Data("keep".utf8).write(to: out.appendingPathComponent("existing.jpg"))
        // A camera JPEG (Exif) without Halfstop edits: --force must not replace it either.
        let camera = out.appendingPathComponent("camera.jpg")
        if let src = CGImageSourceCreateWithURL(b as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
           let dest = CGImageDestinationCreateWithURL(camera as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"]] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        let cameraBytes = try? Data(contentsOf: camera)
        let refusals: [[String]] = [
            ["render", "b.jpg", "-o", "previews/camera.jpg", "--force"],
            ["render", "b.jpg", "-o", "b.jpg"], ["render", "b.jpg", "-o", "./B.JPG", "--force"], ["render", "b.jpg", "-o", "previews/b.jpg"],
            ["render", "b.jpg", "-o", ".halfstop/x.jpg"], ["render", "b.jpg", "-o", "previews/link.jpg", "--force"],
            ["render", "b.jpg", "-o", "previews/x.png"], ["render", "b.jpg", "-o", "nowhere/x.jpg"], ["render", "b.jpg", "-o", "a.jpg", "--force"],
            ["render", "b.jpg", "-o", "previews", "--force"],
        ]
        let refusedCodes = refusals.map { run($0).code }
        check("cli: render refuses the photo, edit files, links, existing files and photos with edits", refusedCodes.allSatisfy { $0 == 1 }
              && !fm.fileExists(atPath: dir.appendingPathComponent("victim.jpg").path) && !fm.fileExists(atPath: dir.appendingPathComponent(".halfstop/x.jpg").path)
              && cameraBytes != nil && (try? Data(contentsOf: camera)) == cameraBytes,
              "\(zip(refusals.map { $0[3] }, refusedCodes).filter { $0.1 != 1 })")
        let forced = run(["render", "b.jpg", "-o", "previews/existing.jpg", "--force"])
        check("cli: --force replaces a plain file", forced.code == 0 && (try? Data(contentsOf: out.appendingPathComponent("existing.jpg")))?.prefix(2) == Data([0xFF, 0xD8]), forced.err)
        check("cli: render leaves no temporary files", ((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).allSatisfy { !$0.hasSuffix(".tmp") }, "")

        // Parallel writers on one photo don't lose updates (the lock).
        let p = dir.appendingPathComponent("parallel.jpg")
        try? fm.copyItem(at: b, to: p)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            _ = try? SidecarLock.with(p, exclusive: true, create: true) {
                var s = SidecarFiles.read(for: p) ?? Sidecar()
                s.ensureHistory()
                s.adjustments.contrast += 1
                s.history.append(HistoryStep(label: "+1", adjustments: s.adjustments, commandLine: true))
                s.historyIndex = s.history.count - 1
                _ = try SidecarFiles.write(s, for: p, history: true)
            }
        }
        check("cli: parallel read-modify-writes all land", sidecar(p).adjustments.contrast == 20 && sidecar(p).history.count == 21, "\(sidecar(p).adjustments.contrast)")

        // Learn from my edits, read-only: command-line steps don't count.
        let lib = dir.appendingPathComponent("learn")
        try? fm.createDirectory(at: lib, withIntermediateDirectories: true)
        let folder = CatalogFolder(path: LibraryFiles.canonical(lib))
        var catalog = Catalog()
        catalog.folders = [folder]
        for i in 0..<22 {
            let name = "p\(i).jpg"
            let url = lib.appendingPathComponent(name)
            try? Data().write(to: url)
            var sc = Sidecar()
            sc.adjustments.exposure = 0.5
            sc.history = [HistoryStep(label: "Original", adjustments: Adjustments()), HistoryStep(label: "x", adjustments: sc.adjustments, commandLine: i == 0)]
            sc.historyIndex = 1
            _ = try? SidecarFiles.write(sc, for: url, history: true)
            catalog.styleSamples[PhotoRef(folder: folder.id, path: name).key] =
                StyleSample(features: (0..<StyleFeatures.count).map { Double(($0 + i) % 5) / 5 }, auto: Array(repeating: 0, count: StyleSliders.count), crop: CropSettings())
        }
        let catalogURL = dir.appendingPathComponent("catalog.json")
        try? catalog.save(to: catalogURL)
        let catalogStamp = SidecarFileState.Stamp(catalogURL)
        let learned = LearnedStyle.load(CommandLineTool.Environment(catalogURL: catalogURL, learnFromEdits: true))
        let off = LearnedStyle.load(CommandLineTool.Environment(catalogURL: catalogURL, learnFromEdits: false))
        check("cli: learned model read from the catalog, without command-line steps", learned?.model.count == 21 && off == nil
              && learned?.key(for: lib.appendingPathComponent("p3.jpg")) == PhotoRef(folder: folder.id, path: "p3.jpg").key
              && SidecarFileState.Stamp(catalogURL) == catalogStamp, "\(learned?.model.count ?? -1)")

        check("cli: photo files never change", photos.map(digest) == originals, "")
    }
}

extension SidecarFiles {
    static func hashForTests(_ data: Data) -> UInt64 { SidecarFileState.hash(data) }
}

// MARK: - Keeping the app in step

extension LibraryTest {
    /// The running app and the command line: changes on disk show up live, the app's own saves are
    /// recognized, and edits made on both sides at once are merged, never lost.
    @MainActor
    static func syncChecks(dir: URL, check: (String, Bool, String) -> Void) async {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let folder = dir.appendingPathComponent("photos")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<3 {
            if let img = SelfTest.scene(width: 400, height: 300, hue: Double(i) / 4, variant: i) {
                SelfTest.write(img, to: folder.appendingPathComponent("s\(i).jpg"))
            }
        }
        let env = CommandLineTool.Environment(catalogURL: nil, learnFromEdits: false, engine: AutoEngine())
        func cli(_ args: [String]) -> Int32 { CommandLineTool.run(args, environment: env, out: { _ in }, err: { _ in }) }
        func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if cond() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return cond()
        }
        func disk(_ url: URL) -> Sidecar {
            var s = SidecarFiles.read(for: url) ?? Sidecar()
            s.ensureHistory()
            return s
        }

        // Pure merge rule.
        var base = Sidecar(); base.ensureHistory()
        var ours = base, theirs = base
        ours.adjustments.contrast = 20; ours.rating = 3
        ours.snapshots = [EditSnapshot(name: "mine", adjustments: ours.adjustments)]
        theirs.adjustments.exposure = -0.5; theirs.adjustments.contrast = 5
        theirs.history.append(HistoryStep(label: "cli", adjustments: theirs.adjustments, commandLine: true)); theirs.historyIndex = 1
        let merged = SidecarMerge.merge(base: base, ours: ours, theirs: theirs, historyLimit: 100)
        check("sync: merge keeps both sides (the app wins where both changed)", merged.keptLocalChanges && merged.sidecar.adjustments.exposure == -0.5
              && merged.sidecar.adjustments.contrast == 20 && merged.sidecar.rating == 3 && merged.sidecar.snapshots.count == 1
              && merged.sidecar.history.count == 3 && merged.sidecar.history[1].adjustments == theirs.adjustments
              && merged.sidecar.historyIndex == 2, "\(merged.sidecar.history.map(\.label))")
        let untouched = SidecarMerge.merge(base: base, ours: base, theirs: theirs, historyLimit: 100)
        check("sync: no local changes, the disk's version as is", !untouched.keptLocalChanges && untouched.sidecar.adjustments == theirs.adjustments
              && untouched.sidecar.history.map(\.id) == theirs.history.map(\.id), "")

        let catalogURL = dir.appendingPathComponent("catalog.json")
        let store = LibraryStore(catalogURL: catalogURL, watch: true)
        store.catalog.folders = [CatalogFolder(path: LibraryFiles.canonical(folder))]
        await withCheckedContinuation { c in store.reload { c.resume() } }
        guard store.photos.count == 3 else {
            check("sync: test library loads", false, "\(store.photos.count)")
            return
        }
        let p0 = store.photos[0], p1 = store.photos[1], p2 = store.photos[2]
        store.select(p0)
        store.mode = .edit
        try? await Task.sleep(for: .milliseconds(300))   // let the watcher start

        check("sync: sidecar paths map to their photos", LibraryStore.photoURL(forSidecarPath: SidecarFiles.historyURL(for: p0.url).path) == p0.url
              && LibraryStore.photoURL(forSidecarPath: SidecarFiles.mainURL(for: p0.url).path) == p0.url
              && LibraryStore.photoURL(forSidecarPath: folder.appendingPathComponent(".halfstop/x.jpg.json.sb-1-ab").path) == nil
              && LibraryStore.photoURL(forSidecarPath: folder.appendingPathComponent("x.jpg.json").path) == nil, "")

        // A command-line edit shows up live (FSEvents), as an undoable step.
        let epoch0 = store.sync.epoch(p0.url)
        _ = cli(["set", p0.url.path, "exposure=0.7"])
        let live = await waitUntil(5) { p0.adjustments.exposure == 0.7 }
        check("sync: a command-line edit shows up in the open editor", live && p0.history.count == 2 && p0.atCommandLineStep
              && store.canUndo && (store.hint ?? "").contains("command line") && store.unsavedCount == 0,
              "exposure \(p0.adjustments.exposure), hint \(store.hint ?? "none")")
        store.undo()
        check("sync: and can be undone in the app", p0.adjustments.exposure == 0 && p0.historyIndex == 0, "")
        let undoneSaved = await waitUntil(3) { store.unsavedCount == 0 && disk(p0.url).historyIndex == 0 }
        check("sync: the undo is saved over it (no conflict)", undoneSaved && disk(p0.url).history.count == 2, "")

        // The app's own saves are recognized and ignored.
        store.set(\.contrast, 15)
        store.commitPending(p0)
        let saved = await waitUntil(3) { store.unsavedCount == 0 }
        let epochBefore = store.sync.epoch(p0.url)
        let stepsBefore = p0.history.count
        await store.checkSidecars([p0.url])
        try? await Task.sleep(for: .milliseconds(600))   // any FSEvents for that save too
        check("sync: the app's own saves don't count as outside changes", saved && store.sync.epoch(p0.url) == epochBefore
              && epochBefore > epoch0 && p0.history.count == stepsBefore && p0.adjustments.contrast == 15
              && disk(p0.url).adjustments.contrast == 15, "epoch \(epoch0)→\(epochBefore)→\(store.sync.epoch(p0.url))")

        // Both sides at once: the app's unsaved change and a command-line edit are merged.
        store.set(\.contrast, 40)            // saved 0.5 s later
        _ = cli(["set", p0.url.path, "exposure=-0.5"])
        let both = await waitUntil(5) {
            store.unsavedCount == 0 && p0.adjustments.exposure == -0.5 && disk(p0.url).adjustments.exposure == -0.5 && disk(p0.url).adjustments.contrast == 40
        }
        check("sync: simultaneous edits are merged, nothing lost", both && p0.adjustments.contrast == 40
              && (store.hint ?? "").contains("Merged"), "app \(p0.adjustments.exposure)/\(p0.adjustments.contrast) disk \(disk(p0.url).adjustments.exposure)/\(disk(p0.url).adjustments.contrast)")
        store.undo()
        check("sync: undo after a merge gives the command-line version", p0.adjustments.exposure == -0.5 && p0.adjustments.contrast == 15
              && p0.atCommandLineStep, "\(p0.adjustments.exposure) \(p0.adjustments.contrast)")
        store.redo()
        _ = await waitUntil(3) { store.unsavedCount == 0 }

        // The same slider on both sides: the app's value is current, the command line's is one undo away.
        store.set(\.exposure, 0.3)
        _ = cli(["set", p0.url.path, "exposure=0.9"])
        _ = await waitUntil(5) { store.unsavedCount == 0 && disk(p0.url).adjustments.exposure == 0.3 && p0.history.contains { $0.adjustments.exposure == 0.9 } }
        let current = p0.adjustments.exposure
        store.undo()
        check("sync: same slider on both sides: app's value current, the other one step back", current == 0.3 && p0.adjustments.exposure == 0.9, "\(current) then \(p0.adjustments.exposure)")
        store.redo()

        // A photo that isn't open, and a save that finds the change first (flush on quit).
        p1.adjustments.vibrance = 10
        store.scheduleSave(p1)
        _ = cli(["set", p1.url.path, "shadows=30"])
        store.flushSaves()
        let flushed = disk(p1.url)
        check("sync: a save that meets a command-line edit merges it (flush)", flushed.adjustments.vibrance == 10 && flushed.adjustments.shadows == 30
              && p1.adjustments.vibrance == 10 && p1.adjustments.shadows == 30, "\(flushed.adjustments.vibrance) \(flushed.adjustments.shadows)")

        // Learning: a photo at a command-line step isn't an edit by hand.
        if store.learnFromEdits {
            store.catalog.styleSamples[p2.ref.key] = StyleSample(features: Array(repeating: 0.5, count: StyleFeatures.count),
                                                                  auto: Array(repeating: 0, count: StyleSliders.count), crop: CropSettings())
            store.select(p2)
            store.set(\.saturation, 12)
            store.commitPending(p2)
            let key = p2.ref.key
            let counted = store.styleModel.entries[key] != nil
            _ = await waitUntil(3) { store.unsavedCount == 0 }
            _ = cli(["set", p2.url.path, "saturation=30"])
            _ = await waitUntil(5) { p2.adjustments.saturation == 30 }
            check("sync: command-line steps don't feed Learn from my edits", counted && store.styleModel.entries[key] == nil && p2.atCommandLineStep,
                  "counted \(counted) after \(store.styleModel.entries[key] != nil) cli \(p2.atCommandLineStep) sat \(p2.adjustments.saturation) current \(store.current === p2)")
            store.undo()
            check("sync: undoing back to a hand edit counts again", store.styleModel.entries[key] != nil, "")
        }
        store.flushSaves()
    }
}
