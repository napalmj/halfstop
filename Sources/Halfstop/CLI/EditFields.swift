import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The global sliders that can be read and set from outside the editor (the `halfstop` command),
/// how values are checked, clamped and rounded, and how they're reported. Masks, curves, HSL,
/// color grading and the crop can't be changed this way.
enum EditFields {
    /// A global slider that can be read and set.
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
              about: "white balance relative to as shot; negative is cooler (bluer), positive warmer (yellower)", step: 1),
        Field(name: "tint", keyPath: \.tint, range: EditLimits.slider,
              about: "white balance tint relative to as shot; negative is greener, positive more magenta", step: 1),
        Field(name: "exposure", keyPath: \.exposure, range: EditLimits.exposure,
              about: "in EV (stops); +1 doubles the brightness", step: 0.01),
        Field(name: "contrast", keyPath: \.contrast, range: EditLimits.slider, about: "contrast", step: 1),
        Field(name: "highlights", keyPath: \.highlights, range: EditLimits.slider,
              about: "negative recovers bright areas, positive brightens them", step: 1),
        Field(name: "shadows", keyPath: \.shadows, range: EditLimits.slider,
              about: "positive lifts dark areas, negative deepens them", step: 1),
        Field(name: "whites", keyPath: \.whites, range: EditLimits.slider, about: "white point; positive brightens the brightest tones", step: 1),
        Field(name: "blacks", keyPath: \.blacks, range: EditLimits.slider, about: "black point; negative deepens the darkest tones", step: 1),
        Field(name: "vibrance", keyPath: \.vibrance, range: EditLimits.slider,
              about: "boosts muted colors more than saturated ones and protects skin", step: 1),
        Field(name: "saturation", keyPath: \.saturation, range: EditLimits.slider,
              about: "all colors equally; -100 is black and white", step: 1),
        Field(name: "vignette", keyPath: \.vignette, range: EditLimits.slider,
              about: "negative darkens the corners, positive lightens them", step: 1),
        Field(name: "sharpening", keyPath: \.sharpening, range: EditLimits.detail, about: "sharpening", step: 1),
        Field(name: "noise_reduction", keyPath: \.noiseReduction, range: EditLimits.detail, about: "noise reduction", step: 1),
    ]
    static let fieldByName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
    static var names: [String] { fields.map(\.name) }

    /// The history step's name when none is given.
    static let defaultLabel = "Command-line edit"
    static let maxLabelLength = 60

    // MARK: Planning an edit

    /// One requested change: `name=value` (absolute), `name+=value` or `name-=value` (relative).
    struct Change: Equatable {
        enum Kind: Equatable { case set, add }
        let name: String
        let kind: Kind
        let value: Double
    }

    struct Plan {
        var adjustments: Adjustments
        /// Field → (from, to), only for fields that change.
        var changes: [String: (Double, Double)]
        /// Fields whose requested value was outside the slider's range.
        var clamped: [String]
    }

    /// The edits after `requested`, each clamped to its slider's range, then rounded to its step.
    /// Assumes `requested` was validated (`validate`).
    static func plan(_ requested: [Change], current: Adjustments) -> Plan {
        var a = current
        var changes: [String: (Double, Double)] = [:]
        var clamped: [String] = []
        for f in fields {
            guard let c = requested.first(where: { $0.name == f.name }) else { continue }
            let old = current[keyPath: f.keyPath]
            let wanted = c.kind == .set ? c.value : old + c.value
            let inRange = wanted.clamped(to: f.range)
            if inRange != wanted { clamped.append(f.name) }
            // Divided by the inverse step, so 0.7 stays 0.7 (70 × 0.01 is 0.7000000000000001). + 0: no "-0".
            let perUnit = (1 / f.step).rounded()
            let value = ((inRange * perUnit).rounded() / perUnit).clamped(to: f.range) + 0
            a[keyPath: f.keyPath] = value
            if value != old { changes[f.name] = (old, value) }
        }
        return Plan(adjustments: a, changes: changes, clamped: clamped)
    }

    /// Why a list of changes can't be used, or nil when it can.
    static func validate(_ requested: [Change]) -> String? {
        guard !requested.isEmpty else { return "Nothing to change: give at least one name=value." }
        var seen = Set<String>()
        for c in requested {
            guard fieldByName[c.name] != nil else {
                return "Unknown slider “\(c.name)”. Sliders: \(names.joined(separator: ", "))."
            }
            guard c.value.isFinite else { return "\(c.name): the value must be a finite number." }
            guard seen.insert(c.name).inserted else { return "\(c.name) is given more than once; give each slider once." }
        }
        return nil
    }

    /// Parses `name=value`, `name+=value` or `name-=value`. nil when `text` doesn't have that shape
    /// (it's then a photo path); `.failure` when it has the shape but the number is bad.
    static func parseChange(_ text: String) -> Result<Change, ParseError>? {
        guard let eq = text.firstIndex(of: "=") else { return nil }
        var name = String(text[..<eq])
        var kind = Change.Kind.set
        var sign = 1.0
        if name.hasSuffix("+") { name.removeLast(); kind = .add }
        else if name.hasSuffix("-") { name.removeLast(); kind = .add; sign = -1 }
        // Letters and underscores (validated against the slider names later); anything else is a file name.
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) || $0 == "_" }) else { return nil }
        let raw = String(text[text.index(after: eq)...])
        guard let value = parseNumber(raw) else {
            return .failure(ParseError("\(name): “\(raw)” isn't a number. Use digits with an optional sign and decimal point, like 0.5 or -20."))
        }
        return .success(Change(name: name, kind: kind, value: sign * value))
    }

    struct ParseError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// A plain decimal number (optional sign, digits, optional fraction, optional exponent). No
    /// hex, no "nan" or "inf", no spaces; a result that overflows to infinity is refused.
    static func parseNumber(_ s: String) -> Double? {
        let bytes = Array(s.utf8)
        var i = 0
        func digits() -> Int {
            let start = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            return i - start
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
        var count = digits()
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") { i += 1; count += digits() }
        guard count > 0 else { return nil }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { return nil }
        }
        guard i == bytes.count, bytes.count <= 64, let d = Double(s), d.isFinite else { return nil }
        return d
    }

    /// One line, no control or invisible formatting characters, at most `maxLabelLength` characters;
    /// `defaultLabel` when nothing is left.
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

    // MARK: Reporting

    static func format(_ v: Double, _ f: Field) -> String {
        f.step < 1 ? String(format: "%.2f", v) : String(format: "%.0f", v)
    }

    static func values(_ a: Adjustments) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, JSONValue.number(a[keyPath: $0.keyPath], places: 2)) }))
    }

    /// "temperature 0, tint 0, exposure 0.50, …"
    static func valuesText(_ a: Adjustments) -> String {
        fields.map { "\($0.name) \(format(a[keyPath: $0.keyPath], $0))" }.joined(separator: ", ")
    }

    /// Edits the command can't change, summarized.
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

    static func otherEditsText(_ a: Adjustments) -> String {
        var parts: [String] = []
        if a.crop.rect != .full { parts.append("cropped (\(a.crop.aspect.label))") }
        if a.crop.angle != 0 { parts.append(String(format: "straightened %.1f°", a.crop.angle)) }
        if !a.masks.isEmpty { parts.append("\(a.masks.count) mask\(a.masks.count == 1 ? "" : "s")") }
        if !a.curveIsIdentity { parts.append("tone curve") }
        if !a.hsl.allSatisfy(\.isNeutral) { parts.append("HSL") }
        if !a.grading.isNeutral { parts.append("color grading") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    static func changes(from a: Adjustments, to b: Adjustments) -> [String: (Double, Double)] {
        var out: [String: (Double, Double)] = [:]
        for f in fields where a[keyPath: f.keyPath] != b[keyPath: f.keyPath] {
            out[f.name] = (a[keyPath: f.keyPath], b[keyPath: f.keyPath])
        }
        if a.crop.angle != b.crop.angle { out["straighten_degrees"] = (a.crop.angle, b.crop.angle) }
        return out
    }

    static func changesJSON(_ changes: [String: (Double, Double)]) -> JSONValue {
        .object(changes.mapValues { ["from": .number($0.0, places: 2), "to": .number($0.1, places: 2)] })
    }

    /// "exposure 0.00 → 0.50, contrast 0 → 10"
    static func describe(_ changes: [String: (Double, Double)]) -> String {
        var parts = fields.compactMap { f -> String? in
            guard let (from, to) = changes[f.name] else { return nil }
            return "\(f.name) \(format(from, f)) → \(format(to, f))"
        }
        if let (from, to) = changes["straighten_degrees"] { parts.append(String(format: "straighten %.1f° → %.1f°", from, to)) }
        return parts.joined(separator: ", ")
    }

    /// The auto analysis of a photo, as reported by `halfstop info`.
    static func insightJSON(_ insight: PhotoInsight) -> JSONValue {
        var out: [String: JSONValue] = [:]
        if let s = insight.stats {
            out["luminance_percentiles"] = .object(Dictionary(uniqueKeysWithValues: [5, 25, 50, 75, 95].map {
                ("p\($0)", JSONValue.number(s.percentile(Double($0) / 100), places: 3))
            }))
            out["mean_rgb_linear"] = .array([s.meanRGB.x, s.meanRGB.y, s.meanRGB.z].map { .number($0, places: 4) })
            out["mean_chroma"] = .number(s.meanChroma, places: 4)
            out["skin_fraction"] = .number(s.skinFraction, places: 3)
        }
        out["scene"] = insight.scene.map { .string($0.rawValue) } ?? .null
        out["faces"] = .array(insight.faces.map {
            ["x": .number($0.minX, places: 3), "y": .number($0.minY, places: 3), "width": .number($0.width, places: 3), "height": .number($0.height, places: 3)]
        })
        out["horizon"] = insight.horizon.map { ["angle_degrees": .number($0.angle, places: 2), "confidence": .number($0.confidence, places: 2)] } ?? .null
        out["auto_straighten_would_set_degrees"] = insight.straightenAngle.map { .number($0, places: 2) } ?? .null
        return .object(out)
    }

    // MARK: Images

    /// Pixel size as the photo is displayed (orientation applied), from its header.
    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(o) ? (h, w) : (w, h)
    }

    /// A JPEG of `image` at most `maxSize` pixels on its long edge, sRGB, with no metadata
    /// (it's drawn into a fresh bitmap, so nothing from the original file can come along).
    static func jpeg(_ image: CGImage, maxSize: Int) -> (data: Data, width: Int, height: Int)? {
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
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
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
}
