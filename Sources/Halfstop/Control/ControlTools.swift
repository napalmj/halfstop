import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The tools an AI app gets: read, look at and edit the photo open in the editor, one undoable
/// history step per change. Only the global sliders below can be changed.
enum ControlTools {
    /// A global slider the tools may read and set.
    struct Field {
        let name: String
        let keyPath: WritableKeyPath<Adjustments, Double>
        let range: ClosedRange<Double>
        /// What it does, with units.
        let about: String
        /// Values are rounded to this step (the sliders' own precision).
        let step: Double
    }

    static let fields: [Field] = [
        Field(name: "temperature", keyPath: \.temperature, range: EditLimits.slider,
              about: "White balance temperature relative to as shot, -100 to 100: negative is cooler (bluer), positive warmer (yellower)", step: 1),
        Field(name: "tint", keyPath: \.tint, range: EditLimits.slider,
              about: "White balance tint relative to as shot, -100 to 100: negative is greener, positive more magenta", step: 1),
        Field(name: "exposure", keyPath: \.exposure, range: EditLimits.exposure,
              about: "Exposure in EV (stops), -5 to 5: +1 doubles the brightness", step: 0.01),
        Field(name: "contrast", keyPath: \.contrast, range: EditLimits.slider, about: "Contrast, -100 to 100", step: 1),
        Field(name: "highlights", keyPath: \.highlights, range: EditLimits.slider,
              about: "Highlights, -100 to 100: negative recovers bright areas, positive brightens them", step: 1),
        Field(name: "shadows", keyPath: \.shadows, range: EditLimits.slider,
              about: "Shadows, -100 to 100: positive lifts dark areas, negative deepens them", step: 1),
        Field(name: "whites", keyPath: \.whites, range: EditLimits.slider, about: "White point, -100 to 100: positive brightens the brightest tones", step: 1),
        Field(name: "blacks", keyPath: \.blacks, range: EditLimits.slider, about: "Black point, -100 to 100: negative deepens the darkest tones", step: 1),
        Field(name: "vibrance", keyPath: \.vibrance, range: EditLimits.slider,
              about: "Vibrance, -100 to 100: boosts muted colors more than saturated ones and protects skin", step: 1),
        Field(name: "saturation", keyPath: \.saturation, range: EditLimits.slider,
              about: "Saturation, -100 to 100: all colors equally; -100 is black and white", step: 1),
        Field(name: "vignette", keyPath: \.vignette, range: EditLimits.slider,
              about: "Vignette, -100 to 100: negative darkens the corners, positive lightens them", step: 1),
        Field(name: "sharpening", keyPath: \.sharpening, range: EditLimits.detail, about: "Sharpening, 0 to 100", step: 1),
        Field(name: "noise_reduction", keyPath: \.noiseReduction, range: EditLimits.detail, about: "Noise reduction, 0 to 100", step: 1),
    ]
    static let fieldByName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })

    static let defaultLabel = "AI edit"
    static let maxLabelLength = 60

    static let names = ["get_photo", "get_adjustments", "get_preview", "set_adjustments", "auto", "auto_straighten", "undo"]

    static let noPhoto = "No photo is open in Halfstop's editor. Ask the user to open one (double-click it in the library, or select it and press E), then try again."

    // MARK: Definitions

    static let definitions: [JSONValue] = {
        let none: JSONValue = ["type": "object", "properties": [:], "additionalProperties": false]
        func annotations(readOnly: Bool, idempotent: Bool) -> JSONValue {
            ["readOnlyHint": .bool(readOnly), "destructiveHint": false, "idempotentHint": .bool(idempotent), "openWorldHint": false]
        }
        let fieldList = fields.map { "\($0.name) (\($0.about))" }.joined(separator: "; ")
        var absolute: [String: JSONValue] = [:], relative: [String: JSONValue] = [:]
        for f in fields {
            absolute[f.name] = ["type": "number", "minimum": .double(f.range.lowerBound), "maximum": .double(f.range.upperBound), "description": .string(f.about)]
            let span = f.range.upperBound - f.range.lowerBound
            relative[f.name] = ["type": "number", "minimum": .double(-span), "maximum": .double(span), "description": .string("Change to add. " + f.about)]
        }
        return [
            [
                "name": "get_photo", "title": "Describe the open photo",
                "description": """
                Describes the photo open in Halfstop's editor: file name (no folder), pixel size, whether it is RAW, \
                rating (0-5) and flag, crop and straighten angle, and an analysis of its current crop: \
                luminance percentiles (0 = black, 1 = white, sRGB-encoded, measured after automatic white balance at \
                exposure 0), mean linear RGB, mean chroma (Oklab; about 0.02 is muted, 0.1 colorful), skin share, \
                faces (normalized boxes, top-left origin), the scene type Auto detected (normal, wellExposed, lowKey, \
                highKey, night) and any horizon (degrees, confidence 0-1). Fails when no photo is open.
                """,
                "inputSchema": none, "annotations": annotations(readOnly: true, idempotent: true),
            ],
            [
                "name": "get_adjustments", "title": "Read the current edits",
                "description": """
                Returns the open photo's current global slider values (the fields set_adjustments can change: \
                \(fields.map(\.name).joined(separator: ", "))), a summary of other edits it cannot change (crop, \
                straighten, masks, tone curve, HSL, color grading) and where the photo is in its edit history.
                """,
                "inputSchema": none, "annotations": annotations(readOnly: true, idempotent: true),
            ],
            [
                "name": "get_preview", "title": "Look at the photo",
                "description": """
                Returns a small JPEG of the open photo as it currently looks, with all edits and the crop applied \
                (at most max_size pixels on the long edge, 512 by default; metadata stripped). Use it to check the \
                result of an edit.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": ["max_size": ["type": "integer", "minimum": 64, "maximum": 512, "default": 512,
                                                "description": "Longest edge in pixels, 64 to 512"]],
                    "additionalProperties": false,
                ],
                "annotations": annotations(readOnly: true, idempotent: true),
            ],
            [
                "name": "set_adjustments", "title": "Change sliders",
                "description": """
                Changes global sliders of the open photo as ONE undoable step in its history. Give absolute values \
                in "values", amounts to add in "deltas" (not the same field in both), and optionally a short "label" \
                for the history step (default "\(defaultLabel)"). Results are clamped to each slider's range and \
                rounded (exposure to 0.01 EV, others to whole numbers). Fields: \(fieldList). Returns what changed.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "values": ["type": "object", "description": "Absolute values to set", "properties": .object(absolute), "additionalProperties": false],
                        "deltas": ["type": "object", "description": "Amounts to add to the current values", "properties": .object(relative), "additionalProperties": false],
                        "label": ["type": "string", "maxLength": .int(maxLabelLength), "description": "Short name for the history step, such as \"Warmer, brighter\""],
                    ],
                    "additionalProperties": false,
                ],
                "annotations": annotations(readOnly: false, idempotent: false),
            ],
            [
                "name": "auto", "title": "✦ Auto",
                "description": """
                Runs Halfstop's one-click Auto on the open photo, as one undoable step "Auto": white balance, exposure, \
                contrast, highlights, shadows, whites, blacks and vibrance, chosen for the scene (well-exposed photos \
                barely change; low-key, high-key and night photos keep their mood; faces are considered). Includes \
                what Halfstop learned from the user's own edits when that is on. Replaces those sliders' values; \
                never changes the crop. A good first step before fine-tuning with set_adjustments.
                """,
                "inputSchema": none, "annotations": annotations(readOnly: false, idempotent: false),
            ],
            [
                "name": "auto_straighten", "title": "Auto straighten",
                "description": """
                Levels a tilted horizon on the open photo by setting the straighten angle (at most 10 degrees), as \
                one undoable step "Auto straighten". Does nothing when no horizon is found or it is already level.
                """,
                "inputSchema": none, "annotations": annotations(readOnly: false, idempotent: true),
            ],
            [
                "name": "undo", "title": "Undo",
                "description": """
                Steps the open photo back one step in its edit history (whatever made that step: you or the user). \
                The user can redo it in Halfstop. Returns the label of the step undone.
                """,
                "inputSchema": none, "annotations": annotations(readOnly: false, idempotent: false),
            ],
        ]
    }()

    // MARK: Reading

    static func values(_ a: Adjustments) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, JSONValue.number(a[keyPath: $0.keyPath], places: 2)) }))
    }

    static func otherEdits(_ a: Adjustments) -> JSONValue {
        [
            "straighten_degrees": .number(a.crop.angle, places: 2),
            "cropped": .bool(a.crop.rect != .full),
            "crop_aspect": .string(a.crop.aspect.label),
            "masks": .int(a.masks.count),
            "tone_curve_edited": .bool(!a.curveIsIdentity),
            "hsl_edited": .bool(!a.hsl.allSatisfy(\.isNeutral)),
            "color_grading_edited": .bool(!a.grading.isNeutral),
        ]
    }

    // MARK: set_adjustments

    struct EditPlan: Equatable {
        var adjustments: Adjustments
        var label: String
        /// Field → (from, to), only for fields that change.
        var changes: [String: (Double, Double)]
        /// Fields whose requested value was outside the slider's range.
        var clamped: [String]

        static func == (a: EditPlan, b: EditPlan) -> Bool {
            a.adjustments == b.adjustments && a.label == b.label && a.clamped == b.clamped
                && a.changes.keys.sorted() == b.changes.keys.sorted()
        }
    }

    /// Validates set_adjustments' arguments and works out the new edits. The error is a message for the model.
    static func planEdit(_ args: [String: JSONValue], current: Adjustments) -> Result<EditPlan, ToolError> {
        for key in args.keys where !["values", "deltas", "label"].contains(key) {
            return .failure(ToolError("Unknown argument \"\(key)\". Use \"values\", \"deltas\" and \"label\"."))
        }
        func numbers(_ key: String) -> Result<[String: Double], ToolError> {
            guard let raw = args[key] else { return .success([:]) }
            guard case .object(let o) = raw else { return .failure(ToolError("\"\(key)\" must be an object of field names to numbers.")) }
            var out: [String: Double] = [:]
            for (name, v) in o {
                guard fieldByName[name] != nil else {
                    return .failure(ToolError("\"\(name)\" can't be changed. Fields: \(fields.map(\.name).joined(separator: ", ")).")) }
                guard let d = v.numberValue, d.isFinite else { return .failure(ToolError("\(key).\(name) must be a number.")) }
                out[name] = d
            }
            return .success(out)
        }
        let absolute: [String: Double], relative: [String: Double]
        switch numbers("values") { case .failure(let e): return .failure(e); case .success(let v): absolute = v }
        switch numbers("deltas") { case .failure(let e): return .failure(e); case .success(let v): relative = v }
        if let both = absolute.keys.sorted().first(where: { relative[$0] != nil }) {
            return .failure(ToolError("\"\(both)\" is in both values and deltas; give it once."))
        }
        guard !absolute.isEmpty || !relative.isEmpty else {
            return .failure(ToolError("Nothing to change: give at least one field in \"values\" or \"deltas\"."))
        }
        var label = defaultLabel
        if let raw = args["label"] {
            guard case .string(let s) = raw else { return .failure(ToolError("\"label\" must be a string.")) }
            label = cleanLabel(s)
        }
        var a = current
        var changes: [String: (Double, Double)] = [:]
        var clamped: [String] = []
        for f in fields {
            let old = current[keyPath: f.keyPath]
            let wanted: Double
            if let v = absolute[f.name] { wanted = v } else if let d = relative[f.name] { wanted = old + d } else { continue }
            let inRange = wanted.clamped(to: f.range)
            if inRange != wanted { clamped.append(f.name) }
            let value = ((inRange / f.step).rounded() * f.step).clamped(to: f.range) + 0   // + 0: no "-0"
            a[keyPath: f.keyPath] = value
            if value != old { changes[f.name] = (old, value) }
        }
        return .success(EditPlan(adjustments: a, label: label, changes: changes, clamped: clamped))
    }

    /// One line, no control or invisible formatting characters, at most `maxLabelLength` characters.
    static func cleanLabel(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                scalars.append(" ")
            default:
                scalars.append(u)
            }
        }
        let words = String(scalars).split(whereSeparator: \.isWhitespace)
        let joined = words.joined(separator: " ")
        let capped = String(joined.prefix(maxLabelLength)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? defaultLabel : capped
    }

    static func describe(_ changes: [String: (Double, Double)]) -> String {
        var parts = fields.compactMap { f -> String? in
            guard let (from, to) = changes[f.name] else { return nil }
            let fmt = f.step < 1 ? "%.2f" : "%.0f"
            return "\(f.name) \(String(format: fmt, from)) → \(String(format: fmt, to))"
        }
        if let (from, to) = changes["straighten_degrees"] { parts.append(String(format: "straighten %.1f° → %.1f°", from, to)) }
        return parts.joined(separator: ", ")
    }

    static func changesJSON(_ changes: [String: (Double, Double)]) -> JSONValue {
        .object(changes.mapValues { ["from": .number($0.0, places: 2), "to": .number($0.1, places: 2)] })
    }

    static func changes(from a: Adjustments, to b: Adjustments) -> [String: (Double, Double)] {
        var out: [String: (Double, Double)] = [:]
        for f in fields where a[keyPath: f.keyPath] != b[keyPath: f.keyPath] {
            out[f.name] = (a[keyPath: f.keyPath], b[keyPath: f.keyPath])
        }
        if a.crop.angle != b.crop.angle { out["straighten_degrees"] = (a.crop.angle, b.crop.angle) }
        return out
    }

    // MARK: Preview

    /// A JPEG of `image` at most `maxSize` pixels on its long edge, sRGB, with no metadata
    /// (it's drawn into a fresh bitmap, so nothing from the original file can come along).
    static func previewJPEG(_ image: CGImage, maxSize: Int) -> (data: Data, width: Int, height: Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, Double(maxSize) / Double(max(w, h)))
        let tw = max(1, Int((Double(w) * scale).rounded())), th = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: Render.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let small = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let clean = stripMetadata(data as Data) else { return nil }
        return (clean, tw, th)
    }

    /// The JPEG without its APP1…APP15 and comment segments. ImageIO always writes a small Exif
    /// block (pixel size, color space) and an APP13 block; neither is needed to show the image.
    static func stripMetadata(_ jpeg: Data) -> Data? {
        let b = [UInt8](jpeg)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var out: [UInt8] = [0xFF, 0xD8]
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xDA {
                // Start of scan: the entropy-coded data and the rest of the file follow as is.
                out.append(contentsOf: b[i...])
                return Data(out)
            }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { return nil }
            if !((0xE1...0xEF).contains(marker) || marker == 0xFE) {
                out.append(contentsOf: b[i..<(i + 2 + length)])
            }
            i += 2 + length
        }
        return nil
    }

    /// Pixel size as the photo is displayed (orientation applied), from its header.
    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(o) ? (h, w) : (w, h)
    }
}

struct ToolError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Running the tools against the library

/// Runs the tools on the store's open photo. Store access happens on the main actor; decoding,
/// measuring and JPEG encoding happen off it.
final class StoreToolRunner: ControlToolRunner, @unchecked Sendable {
    /// Read and written only on the main actor.
    private weak var store: LibraryStore?

    @MainActor init(store: LibraryStore) { self.store = store }

    var tools: [JSONValue] { ControlTools.definitions }
    func knows(_ name: String) -> Bool { ControlTools.names.contains(name) }

    func call(_ name: String, arguments: [String: JSONValue]) async -> ToolResult {
        if name != "set_adjustments" && name != "get_preview" && !arguments.isEmpty {
            return .error("\(name) takes no arguments.")
        }
        switch name {
        case "get_photo": return await getPhoto()
        case "get_adjustments": return await getAdjustments()
        case "get_preview": return await getPreview(arguments)
        case "set_adjustments": return await setAdjustments(arguments)
        case "auto": return await auto(.auto)
        case "auto_straighten": return await auto(.straighten)
        case "undo": return await undo()
        default: return .error("Unknown tool \(name).")
        }
    }

    /// The store and the photo open in the editor.
    @MainActor private func open() -> (LibraryStore, Photo)? {
        guard let store, store.mode == .edit, let photo = store.current else { return nil }
        return (store, photo)
    }

    private static func reply(_ summary: String, _ structured: JSONValue) -> ToolResult {
        ToolResult(content: [.text(summary), .text(structured.text)], structured: structured)
    }

    // MARK: Reading

    private func getPhoto() async -> ToolResult {
        struct Snap: Sendable {
            let url: URL, name: String, raw: Bool, rating: Int, flag: String, adjustments: Adjustments, adapted: Bool
        }
        let snap: Snap? = await MainActor.run {
            guard let (store, p) = open() else { return nil }
            return Snap(url: p.url, name: p.name, raw: p.isRAW, rating: p.rating, flag: p.flag.rawValue,
                        adjustments: p.adjustments, adapted: store.autoIsAdapted)
        }
        guard let snap else { return .error(ControlTools.noPhoto) }
        let url = snap.url
        let size = await Task.detached(priority: .userInitiated) { ControlTools.pixelSize(url) }.value
        let insight = await AutoEngine.shared.insight(url: url, adjustments: snap.adjustments)
        var analysis: [String: JSONValue] = [:]
        if let s = insight?.stats {
            analysis["luminance_percentiles"] = .object(Dictionary(uniqueKeysWithValues: [5, 25, 50, 75, 95].map {
                ("p\($0)", JSONValue.number(s.percentile(Double($0) / 100), places: 3))
            }))
            analysis["mean_rgb_linear"] = .array([s.meanRGB.x, s.meanRGB.y, s.meanRGB.z].map { .number($0, places: 4) })
            analysis["mean_chroma"] = .number(s.meanChroma, places: 4)
            analysis["skin_fraction"] = .number(s.skinFraction, places: 3)
        }
        if let insight {
            analysis["scene"] = insight.scene.map { .string($0.rawValue) } ?? .null
            analysis["faces"] = .array(insight.faces.map {
                ["x": .number($0.minX, places: 3), "y": .number($0.minY, places: 3), "width": .number($0.width, places: 3), "height": .number($0.height, places: 3)]
            })
            analysis["horizon"] = insight.horizon.map { ["angle_degrees": .number($0.angle, places: 2), "confidence": .number($0.confidence, places: 2)] } ?? .null
            analysis["auto_straighten_would_set_degrees"] = insight.straightenAngle.map { .number($0, places: 2) } ?? .null
        }
        let a = snap.adjustments
        let info: JSONValue = [
            "file_name": .string(snap.name),
            "raw": .bool(snap.raw),
            "width": size.map { .int($0.0) } ?? .null,
            "height": size.map { .int($0.1) } ?? .null,
            "rating": .int(snap.rating),
            "flag": .string(snap.flag),
            "edited": .bool(!a.isDefault),
            "crop": ["cropped": .bool(a.crop.rect != .full), "aspect": .string(a.crop.aspect.label), "straighten_degrees": .number(a.crop.angle, places: 2)],
            "analysis": insight == nil ? .null : .object(analysis),
            "auto_adapted_to_user_edits": .bool(snap.adapted),
        ]
        let dims = size.map { "\($0.0)×\($0.1)" } ?? "unknown size"
        return Self.reply("\(snap.name), \(dims)\(snap.raw ? ", RAW" : "")\(insight == nil ? " (couldn't be analyzed)" : "")", info)
    }

    private func getAdjustments() async -> ToolResult {
        await MainActor.run {
            guard let (store, p) = open() else { return .error(ControlTools.noPhoto) }
            let a = p.adjustments
            let index = min(p.historyIndex, p.history.count - 1)
            let info: JSONValue = [
                "values": ControlTools.values(a),
                "other_edits": ControlTools.otherEdits(a),
                "history": [
                    "steps": .int(p.history.count),
                    "current_step": .int(index + 1),
                    "current_label": .string(p.history.indices.contains(index) ? p.history[index].label : ""),
                    "can_undo": .bool(store.canUndo),
                ],
            ]
            return Self.reply("Current edits of \(p.name)", info)
        }
    }

    private func getPreview(_ args: [String: JSONValue]) async -> ToolResult {
        for key in args.keys where key != "max_size" { return .error("Unknown argument \"\(key)\". get_preview takes only max_size.") }
        var maxSize = 512
        if let raw = args["max_size"] {
            guard let d = raw.numberValue, d == d.rounded(), (64...512).contains(d) else {
                return .error("max_size must be a whole number from 64 to 512.")
            }
            maxSize = Int(d)
        }
        let snap: (URL, String, Adjustments)? = await MainActor.run {
            guard let (_, p) = open() else { return nil }
            return (p.url, p.name, p.adjustments)
        }
        guard let (url, name, adjustments) = snap else { return .error(ControlTools.noPhoto) }
        guard let image = await ThumbnailService.shared.image(url: url, adjustments: adjustments) else {
            return .error("Halfstop couldn't render \(name).")
        }
        let size = maxSize
        guard let jpeg = await Task.detached(priority: .userInitiated, operation: { ControlTools.previewJPEG(image, maxSize: size) }).value else {
            return .error("Halfstop couldn't encode a preview of \(name).")
        }
        return ToolResult(content: [.image(jpeg.data, mimeType: "image/jpeg"),
                                    .text("Preview of \(name) with its current edits, \(jpeg.width)×\(jpeg.height) JPEG.")])
    }

    // MARK: Editing

    private func setAdjustments(_ args: [String: JSONValue]) async -> ToolResult {
        await MainActor.run {
            guard let (store, p) = open() else { return .error(ControlTools.noPhoto) }
            // Settle a slider drag in progress first, so the plan starts from what's on screen.
            store.commitPending(p)
            switch ControlTools.planEdit(args, current: p.adjustments) {
            case .failure(let e):
                return .error(e.message)
            case .success(let plan):
                let applied = store.applyToCurrent(plan.adjustments, label: plan.label)
                if applied { store.showHint("AI control: \(plan.label)") }
                var info: [String: JSONValue] = [
                    "applied": .bool(applied),
                    "label": .string(plan.label),
                    "changes": ControlTools.changesJSON(plan.changes),
                    "values": ControlTools.values(p.adjustments),
                ]
                if !plan.clamped.isEmpty { info["clamped_to_range"] = .array(plan.clamped.map { .string($0) }) }
                let clampNote = plan.clamped.isEmpty ? "" : " Clamped to the slider range: \(plan.clamped.joined(separator: ", "))."
                let summary = applied
                    ? "Applied as one history step “\(plan.label)”: \(ControlTools.describe(plan.changes)).\(clampNote)"
                    : "Nothing changed: the sliders already have those values.\(clampNote)"
                return Self.reply(summary, .object(info))
            }
        }
    }

    private func auto(_ kind: AutoKind) async -> ToolResult {
        let started: (Task<AutoOutcome, Never>, URL, Adjustments)?? = await MainActor.run {
            guard let (store, p) = open() else { return .some(nil) }
            store.commitPending(p)
            guard let task = store.performAuto(kind) else { return nil }
            return (task, p.url, p.adjustments)
        }
        guard let started else { return .error("Another auto action is still running on this photo. Try again in a moment.") }
        guard let (task, url, before) = started else { return .error(ControlTools.noPhoto) }
        let outcome = await task.value
        return await MainActor.run {
            let after = store?.photo(for: url)?.adjustments ?? before
            let changes = ControlTools.changes(from: before, to: after)
            var info: [String: JSONValue] = ["outcome": .string("\(outcome)"), "values": ControlTools.values(after)]
            switch outcome {
            case .applied:
                info["changes"] = ControlTools.changesJSON(changes)
                if kind == .auto { info["adapted_to_user_edits"] = .bool(store?.autoIsAdapted ?? false) }
                store?.showHint("AI control: \(kind.label)")
                return Self.reply("Applied as one history step “\(kind.label)”: \(ControlTools.describe(changes)).", .object(info))
            case .unchanged:
                return Self.reply(kind == .straighten ? "The horizon is already level; nothing changed." : "Auto found nothing to change.", .object(info))
            case .noHorizon:
                return Self.reply("No horizon found; nothing changed.", .object(info))
            case .stale:
                return .error("The open photo or its edits changed while \(kind.label) was measuring, so nothing was applied. Call it again if still wanted.")
            case .unreadable:
                return .error("Halfstop couldn't read this photo.")
            }
        }
    }

    private func undo() async -> ToolResult {
        await MainActor.run {
            guard let (store, p) = open() else { return .error(ControlTools.noPhoto) }
            store.commitPending(p)
            guard p.historyIndex > 0, p.history.indices.contains(p.historyIndex) else {
                return Self.reply("Nothing to undo: the photo is at the start of its history.", ["undone": false, "values": ControlTools.values(p.adjustments)])
            }
            let label = p.history[p.historyIndex].label
            let before = p.adjustments
            store.undo()
            store.showHint("AI control: Undo \(label)")
            let info: JSONValue = [
                "undone": true, "undone_step": .string(label),
                "changes": ControlTools.changesJSON(ControlTools.changes(from: before, to: p.adjustments)),
                "values": ControlTools.values(p.adjustments),
            ]
            return Self.reply("Undid “\(label)”. The user can redo it with ⇧⌘Z.", info)
        }
    }
}
