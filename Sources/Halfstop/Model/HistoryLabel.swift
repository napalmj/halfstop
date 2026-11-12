import Foundation

/// Names a history step by comparing the edits before and after it.
enum HistoryLabel {
    private typealias Global = (name: String, key: WritableKeyPath<Adjustments, Double>, ev: Bool)
    private typealias Local = (name: String, key: WritableKeyPath<LocalAdjustments, Double>, ev: Bool)

    private static let globals: [Global] = [
        ("Exposure", \.exposure, true), ("Contrast", \.contrast, false), ("Highlights", \.highlights, false),
        ("Shadows", \.shadows, false), ("Whites", \.whites, false), ("Blacks", \.blacks, false),
        ("Temperature", \.temperature, false), ("Tint", \.tint, false), ("Vibrance", \.vibrance, false),
        ("Saturation", \.saturation, false), ("Vignette", \.vignette, false), ("Sharpening", \.sharpening, false),
        ("Noise reduction", \.noiseReduction, false),
    ]

    private static let locals: [Local] = [
        ("Exposure", \.exposure, true), ("Contrast", \.contrast, false), ("Highlights", \.highlights, false),
        ("Shadows", \.shadows, false), ("Whites", \.whites, false), ("Blacks", \.blacks, false),
        ("Temperature", \.temperature, false), ("Tint", \.tint, false), ("Vibrance", \.vibrance, false),
        ("Saturation", \.saturation, false),
    ]

    static func value(_ v: Double, ev: Bool) -> String {
        if ev { return String(format: v > 0 ? "+%.2f" : "%.2f", v) }
        let r = Int(v.rounded())
        return r > 0 ? "+\(r)" : "\(r)"
    }

    static func describe(from a: Adjustments, to b: Adjustments) -> String {
        var parts: [String] = []

        let changedGlobals = globals.filter { a[keyPath: $0.key] != b[keyPath: $0.key] }
        if changedGlobals.count > 2 {
            parts.append("\(changedGlobals.count) adjustments")
        } else {
            parts += changedGlobals.map { "\($0.name) \(value(b[keyPath: $0.key], ev: $0.ev))" }
        }

        if a.curve != b.curve { parts.append(b.curveIsIdentity ? "Reset tone curve" : "Tone curve") }
        if a.hsl != b.hsl { parts.append(hsl(a.hsl, b.hsl)) }
        if a.grading != b.grading { parts.append(grading(a.grading, b.grading)) }
        if a.crop != b.crop { parts.append(crop(a.crop, b.crop)) }
        parts += masks(a.masks, b.masks)

        switch parts.count {
        case 0: return "Edit"
        case 1, 2: return parts.joined(separator: ", ")
        default: return "\(parts[0]) and \(parts.count - 1) more"
        }
    }

    private static func hsl(_ a: [HSLBand], _ b: [HSLBand]) -> String {
        var changes: [String] = []
        for color in HSLColor.allCases where a[color.rawValue] != b[color.rawValue] {
            let x = a[color.rawValue], y = b[color.rawValue]
            if x.hue != y.hue { changes.append("\(color.name) hue \(value(y.hue, ev: false))") }
            if x.saturation != y.saturation { changes.append("\(color.name) saturation \(value(y.saturation, ev: false))") }
            if x.luminance != y.luminance { changes.append("\(color.name) luminance \(value(y.luminance, ev: false))") }
        }
        return changes.count == 1 ? "HSL: \(changes[0])" : "HSL"
    }

    private static func grading(_ a: ColorGrading, _ b: ColorGrading) -> String {
        var which: [String] = []
        if a.shadows != b.shadows { which.append("shadows") }
        if a.midtones != b.midtones { which.append("midtones") }
        if a.highlights != b.highlights { which.append("highlights") }
        if a.balance != b.balance { which.append("balance") }
        if b.isNeutral && b.balance == 0 { return "Reset color grading" }
        return which.count == 1 ? "Color grading: \(which[0])" : "Color grading"
    }

    private static func crop(_ a: CropSettings, _ b: CropSettings) -> String {
        if b.isIdentity { return "Reset crop" }
        if a.angle != b.angle && a.rect == b.rect { return String(format: "Straighten %.1f°", b.angle) }
        if a.aspect != b.aspect || a.portrait != b.portrait { return "Crop \(b.aspect.label)" }
        return "Crop"
    }

    private static func masks(_ a: [Mask], _ b: [Mask]) -> [String] {
        var out: [String] = []
        let before = Dictionary(a.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let after = Set(b.map(\.id))
        for m in b where before[m.id] == nil { out.append("Add mask: \(m.name)") }
        for m in a where !after.contains(m.id) { out.append("Delete mask: \(m.name)") }
        for m in b {
            guard let old = before[m.id], old != m else { continue }
            if old.local != m.local {
                let changed = locals.filter { old.local[keyPath: $0.key] != m.local[keyPath: $0.key] }
                if changed.count == 1 {
                    out.append("\(m.name): \(changed[0].name) \(value(m.local[keyPath: changed[0].key], ev: changed[0].ev))")
                } else {
                    out.append("\(m.name): \(changed.count) adjustments")
                }
            }
            if old.enabled != m.enabled { out.append(m.enabled ? "Show \(m.name)" : "Hide \(m.name)") }
            if old.invert != m.invert { out.append(m.invert ? "Invert \(m.name)" : "Uninvert \(m.name)") }
            if old.strokes != m.strokes {
                if m.strokes.count > old.strokes.count {
                    let erase = m.strokes.last?.erase ?? false
                    out.append(m.kind == .brush ? "\(m.name): \(erase ? "erase" : "paint")" : "\(m.name): refine \(erase ? "subtract" : "add")")
                } else if m.strokes.isEmpty {
                    out.append("\(m.name): clear brush")
                } else {
                    out.append("\(m.name): brush")
                }
            }
            if old.shapes.count < m.shapes.count { out.append("\(m.name): add shape") }
            else if old.shapes.count > m.shapes.count { out.append("\(m.name): remove shape") }
            else if old.shapes != m.shapes {
                let modeChanged = zip(old.shapes, m.shapes).contains { $0.mode != $1.mode }
                out.append(modeChanged ? "\(m.name): shape mode" : "\(m.name): move shape")
            }
            if old.subjects != m.subjects { out.append("\(m.name): choose subjects") }
            if old.grow != m.grow { out.append("\(m.name): grow \(value(m.grow, ev: false))") }
            if old.softness != m.softness { out.append("\(m.name): softness \(value(m.softness, ev: false))") }
            if old.center != m.center || old.radiusX != m.radiusX || old.radiusY != m.radiusY
                || old.start != m.start || old.end != m.end || old.feather != m.feather {
                out.append("Adjust \(m.name)")
            }
            if old.name != m.name { out.append("Rename \(old.name)") }
        }
        return out
    }
}
