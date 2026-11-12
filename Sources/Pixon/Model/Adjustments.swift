import Foundation
import CoreGraphics

/// A point on the tone curve, both coordinates in 0...1.
struct CurvePoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// Per-color hue / saturation / luminance offsets, each in -100...100.
struct HSLBand: Codable, Hashable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

enum HSLColor: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    var id: Int { rawValue }

    /// Center hue in degrees.
    var centerHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 225
        case .purple: 270
        case .magenta: 315
        }
    }

    var name: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .aqua: "Aqua"
        case .blue: "Blue"
        case .purple: "Purple"
        case .magenta: "Magenta"
        }
    }
}

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case free, original, square, fourFive, threeTwo, sixteenNine

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .fourFive: "4:5"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        }
    }

    /// Width / height ratio for the long-edge-horizontal orientation, nil when unconstrained.
    func ratio(original: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original: original.width / max(original.height, 1)
        case .square: 1
        case .fourFive: 4.0 / 5.0
        case .threeTwo: 3.0 / 2.0
        case .sixteenNine: 16.0 / 9.0
        }
    }
}

/// Normalized rectangle (0...1, top-left origin).
struct NormRect: Codable, Hashable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1

    static let full = NormRect()

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
}

/// Crop and straighten. `rect` is normalized (top-left origin) inside the straightened frame.
struct CropSettings: Codable, Hashable {
    var rect = NormRect.full
    /// Straighten angle in degrees, -45...45.
    var angle: Double = 0
    var aspect: AspectRatio = .free
    /// Flip the aspect ratio to portrait.
    var portrait = false

    /// Desired crop width/height in pixels, nil when unconstrained.
    func pixelRatio(imageSize: CGSize) -> Double? {
        guard let r = aspect.ratio(original: imageSize) else { return nil }
        return portrait ? 1 / r : r
    }

    var isIdentity: Bool {
        angle == 0 && rect == .full
    }
}

// MARK: - Color grading

/// One color wheel: hue in degrees, strength 0...100, luminance -100...100.
struct GradeWheel: Codable, Hashable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    var isNeutral: Bool { saturation == 0 && luminance == 0 }
}

struct ColorGrading: Codable, Hashable {
    var shadows = GradeWheel(hue: 220)
    var midtones = GradeWheel(hue: 40)
    var highlights = GradeWheel(hue: 45)
    /// Shifts the split between shadows and highlights, -100...100.
    var balance: Double = 0

    var isNeutral: Bool { shadows.isNeutral && midtones.isNeutral && highlights.isNeutral }
}

// MARK: - Masks

struct NormPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// Adjustments a mask applies to its area. Same ranges as the global sliders.
struct LocalAdjustments: Codable, Hashable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0

    var isNeutral: Bool { self == LocalAdjustments() }
}

enum MaskKind: String, Codable, CaseIterable, Identifiable {
    case brush, linear, radial, subject, sky
    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .linear: "rectangle.tophalf.filled"
        case .radial: "circle.dashed"
        case .subject: "person.crop.rectangle"
        case .sky: "cloud.sun"
        }
    }

    /// Detected from the image rather than drawn.
    var isAutomatic: Bool { self == .subject || self == .sky }
}

/// A brush stroke. Points are normalized to the oriented image; radius is a fraction of its long edge.
struct BrushStroke: Codable, Hashable {
    var points: [NormPoint] = []
    var radius: Double = 0.04
    /// 0 = hard edge, 1 = very soft.
    var feather: Double = 0.6
    var flow: Double = 1
    var erase = false
}

/// A local adjustment area. Geometry is normalized (top-left origin) to the oriented,
/// uncropped image, so crops never move masks.
struct Mask: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var kind: MaskKind
    var enabled = true
    var invert = false
    // Radial
    var center = NormPoint(x: 0.5, y: 0.5)
    var radiusX = 0.25
    var radiusY = 0.25
    var feather = 0.5
    // Linear: fully applied at `start`, fading to nothing at `end`.
    var start = NormPoint(x: 0.5, y: 0.25)
    var end = NormPoint(x: 0.5, y: 0.6)
    // Brush
    var strokes: [BrushStroke] = []

    var local = LocalAdjustments()
}

/// Every non-destructive edit applied to a photo. Ranges are Lightroom-like.
struct Adjustments: Codable, Hashable {
    // White balance, -100...100 (relative to as-shot)
    var temperature: Double = 0
    var tint: Double = 0
    // Light
    var exposure: Double = 0       // EV, -5...5
    var contrast: Double = 0       // -100...100
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    // Color
    var vibrance: Double = 0
    var saturation: Double = 0
    // Effects
    var vignette: Double = 0       // -100...100 (negative darkens edges)
    var sharpening: Double = 0     // 0...100
    var noiseReduction: Double = 0 // 0...100
    // Curve & HSL
    var curve: [CurvePoint] = Adjustments.identityCurve
    var hsl: [HSLBand] = Array(repeating: HSLBand(), count: HSLColor.allCases.count)
    // Color grading wheels
    var grading = ColorGrading()
    // Local adjustments
    var masks: [Mask] = []
    // Geometry
    var crop = CropSettings()

    static let identityCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    init() {}

    var isDefault: Bool { self == Adjustments() }

    var curveIsIdentity: Bool { curve == Adjustments.identityCurve }

    /// Everything except crop — what copy/paste carries over.
    func withCrop(from other: Adjustments) -> Adjustments {
        var copy = self
        copy.crop = other.crop
        return copy
    }

    /// Global look only — what presets carry over (keeps the target's crop and masks).
    func asPreset(onto other: Adjustments) -> Adjustments {
        var copy = self
        copy.crop = other.crop
        copy.masks = other.masks
        return copy
    }

    // Tolerant decoding so sidecars and presets survive new fields being added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Adjustments()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        temperature = v(.temperature, d.temperature)
        tint = v(.tint, d.tint)
        exposure = v(.exposure, d.exposure)
        contrast = v(.contrast, d.contrast)
        highlights = v(.highlights, d.highlights)
        shadows = v(.shadows, d.shadows)
        whites = v(.whites, d.whites)
        blacks = v(.blacks, d.blacks)
        vibrance = v(.vibrance, d.vibrance)
        saturation = v(.saturation, d.saturation)
        vignette = v(.vignette, d.vignette)
        sharpening = v(.sharpening, d.sharpening)
        noiseReduction = v(.noiseReduction, d.noiseReduction)
        curve = v(.curve, d.curve)
        var bands = v(.hsl, d.hsl)
        if bands.count != HSLColor.allCases.count { bands = d.hsl }
        hsl = bands
        grading = v(.grading, d.grading)
        masks = v(.masks, d.masks)
        crop = v(.crop, d.crop)
    }
}

/// The part of the adjustments baked into the color lookup table.
struct ColorLUTKey: Hashable {
    var contrast: Double
    var highlights: Double
    var whites: Double
    var blacks: Double
    var curve: [CurvePoint]
    var hsl: [HSLBand]
    var grading: ColorGrading

    init(_ a: Adjustments) {
        contrast = a.contrast
        highlights = max(0, a.highlights)
        whites = a.whites
        blacks = a.blacks
        curve = a.curve
        hsl = a.hsl
        grading = a.grading
    }

    /// Tone-only key for a mask's local contrast / whites / blacks.
    init(local l: LocalAdjustments) {
        contrast = l.contrast
        highlights = max(0, l.highlights)
        whites = l.whites
        blacks = l.blacks
        curve = Adjustments.identityCurve
        hsl = Array(repeating: HSLBand(), count: HSLColor.allCases.count)
        grading = ColorGrading()
    }

    var isIdentity: Bool {
        contrast == 0 && highlights == 0 && whites == 0 && blacks == 0
            && curve == Adjustments.identityCurve && hsl.allSatisfy(\.isNeutral) && grading.isNeutral
    }
}
