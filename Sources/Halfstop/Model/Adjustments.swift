import Foundation
import CoreGraphics

/// Bounds applied when edits are loaded, so a damaged or crafted file can't send absurd values
/// to the renderer (a stroke 1e8 image-widths long, a mask grown by 1e6, a crop of negative size).
/// They're wider than anything the editor produces, so real edits load unchanged.
enum EditLimits {
    /// Normalized coordinates: strokes and shapes may run off the image, but not to infinity.
    static let coordinate = -50.0...50.0
    static let brushRadius = 0.0005...0.5
    static let unit = 0.0...1.0
    static let shapeRadius = 0.001...10.0
    static let grow = -100.0...100.0
    static let softness = 0.0...100.0
    static let straighten = -45.0...45.0
    /// The global sliders, as the panel shows them (values from outside, like the `halfstop` command, are clamped to these).
    static let slider = -100.0...100.0
    static let exposure = -5.0...5.0
    static let detail = 0.0...100.0
    static let minCropSide = 0.0001
    static let pointsPerStroke = 50_000
    static let strokesPerMask = 20_000
    static let shapesPerMask = 200
    static let masks = 500
    static let curvePoints = 1_000
    static let spots = 2_000
    static let spotRadius = 0.001...0.25
    static let grainSize = 1.0...4.0
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

extension TolerantContainer {
    /// Like `array`, keeping at most `limit` elements (the rest count as dropped).
    func array<T: Decodable>(_ key: K, default fallback: [T], limit: Int) -> [T] {
        var a: [T] = array(key, default: fallback)
        if a.count > limit {
            noteDropped()
            a.removeSubrange(limit...)
        }
        return a
    }
}

/// A point on the tone curve, both coordinates in 0...1.
struct CurvePoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        x = try t.required(.x, as: Double.self).clamped(to: EditLimits.unit)
        y = try t.required(.y, as: Double.self).clamped(to: EditLimits.unit)
    }
}

/// Per-color hue / saturation / luminance offsets, each in -100...100.
struct HSLBand: Codable, Hashable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }

    init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        hue = t.value(.hue, 0); saturation = t.value(.saturation, 0); luminance = t.value(.luminance, 0)
    }
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

    /// Inside the unit square with a positive size (a crop rect can't be anything else).
    var clampedToUnit: NormRect {
        let m = EditLimits.minCropSide
        var r = self
        r.x = x.clamped(to: 0...(1 - m)); r.y = y.clamped(to: 0...(1 - m))
        r.width = width.clamped(to: m...(1 - r.x)); r.height = height.clamped(to: m...(1 - r.y))
        return r
    }

    init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        x = t.value(.x, 0); y = t.value(.y, 0); width = t.value(.width, 1); height = t.value(.height, 1)
    }
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

    init() {}

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        rect = t.value(.rect, NormRect.full).clampedToUnit
        angle = t.value(.angle, 0.0).clamped(to: EditLimits.straighten)
        aspect = t.value(.aspect, .free)
        portrait = t.value(.portrait, false)
    }
}

// MARK: - Color grading

/// One color wheel: hue in degrees, strength 0...100, luminance -100...100.
struct GradeWheel: Codable, Hashable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    var isNeutral: Bool { saturation == 0 && luminance == 0 }

    init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        hue = t.value(.hue, 0); saturation = t.value(.saturation, 0); luminance = t.value(.luminance, 0)
    }
}

struct ColorGrading: Codable, Hashable {
    var shadows = GradeWheel(hue: 220)
    var midtones = GradeWheel(hue: 40)
    var highlights = GradeWheel(hue: 45)
    /// Shifts the split between shadows and highlights, -100...100.
    var balance: Double = 0

    var isNeutral: Bool { shadows.isNeutral && midtones.isNeutral && highlights.isNeutral }

    init() {}

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        let d = ColorGrading()
        shadows = t.value(.shadows, d.shadows)
        midtones = t.value(.midtones, d.midtones)
        highlights = t.value(.highlights, d.highlights)
        balance = t.value(.balance, d.balance)
    }
}

// MARK: - Curves

/// The tone curve as four region sliders. Each pulls its part of the tonal range up or down;
/// the three splits (0...1, increasing) set where shadows, darks, lights and highlights meet.
struct ParametricCurve: Codable, Hashable {
    var shadows: Double = 0
    var darks: Double = 0
    var lights: Double = 0
    var highlights: Double = 0
    var split1: Double = 0.25
    var split2: Double = 0.5
    var split3: Double = 0.75

    var isNeutral: Bool { shadows == 0 && darks == 0 && lights == 0 && highlights == 0 }

    init() {}

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        let d = ParametricCurve()
        shadows = t.value(.shadows, d.shadows).clamped(to: EditLimits.slider)
        darks = t.value(.darks, d.darks).clamped(to: EditLimits.slider)
        lights = t.value(.lights, d.lights).clamped(to: EditLimits.slider)
        highlights = t.value(.highlights, d.highlights).clamped(to: EditLimits.slider)
        let a = t.value(.split1, d.split1).clamped(to: 0.05...0.95)
        let b = t.value(.split2, d.split2).clamped(to: 0.05...0.95)
        let c = t.value(.split3, d.split3).clamped(to: 0.05...0.95)
        let sorted = [a, b, c].sorted()
        split1 = sorted[0]; split2 = sorted[1]; split3 = sorted[2]
    }
}

/// Curves over the color wheel: x is the hue (0...1 = 0°...360°, wrapping), y is the change,
/// with 0.5 meaning none. Empty means flat.
struct HueCurves: Codable, Hashable {
    /// Shifts each hue toward its neighbors (up to ±60°).
    var hue: [CurvePoint] = []
    /// Scales saturation (0 = gray, 1 = double).
    var saturation: [CurvePoint] = []
    /// Brightens or darkens each color.
    var luminance: [CurvePoint] = []

    var isNeutral: Bool { [hue, saturation, luminance].allSatisfy { $0.allSatisfy { abs($0.y - 0.5) < 1e-6 } } }

    init() {}

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        hue = t.array(.hue, default: [], limit: 64)
        saturation = t.array(.saturation, default: [], limit: 64)
        luminance = t.array(.luminance, default: [], limit: 64)
    }
}

/// One of the three hue curves.
enum HueCurveChannel: String, CaseIterable, Identifiable {
    case hue, saturation, luminance
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .luminance: "Luminance"
        }
    }
    var keyPath: WritableKeyPath<HueCurves, [CurvePoint]> {
        switch self {
        case .hue: \.hue
        case .saturation: \.saturation
        case .luminance: \.luminance
        }
    }
}

extension HueCurves {
    /// Half-width (in hue, 0...1) a new point affects: anchors go this far on each side.
    static let anchorSpan = 0.08

    /// Sets the curve at `x` to `y`, adding the point (with neutral anchors on both sides, so only
    /// nearby colors change) when there's none close by. Returns the point's index.
    @discardableResult
    static func setPoint(_ points: inout [CurvePoint], x x0: Double, y: Double, near: Double = 0.02) -> Int {
        let x = x0 - floor(x0)
        func dist(_ a: Double) -> Double { let d = abs(a - x); return min(d, 1 - d) }
        if let i = points.indices.min(by: { dist(points[$0].x) < dist(points[$1].x) }), dist(points[i].x) < near {
            points[i].y = y.clamped(to: EditLimits.unit)
            return i
        }
        if !points.contains(where: { dist($0.x) < anchorSpan * 1.4 }) {
            for dx in [-anchorSpan, anchorSpan] {
                let ax = x + dx - floor(x + dx)
                points.append(CurvePoint(x: ax, y: PeriodicCurve(points: points).evaluate(ax)))
            }
        }
        points.append(CurvePoint(x: x, y: y.clamped(to: EditLimits.unit)))
        points.sort { $0.x < $1.x }
        return points.firstIndex { $0.x == x } ?? 0
    }
}

// MARK: - Effects and lens

struct Grain: Codable, Hashable {
    /// 0...100.
    var amount: Double = 0
    /// Grain size, 1...4 (×, relative to a 24-megapixel frame).
    var size: Double = 1.5
    /// 0 = smooth, 100 = coarse and clumpy.
    var roughness: Double = 50

    init() {}

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        let d = Grain()
        amount = t.value(.amount, d.amount).clamped(to: EditLimits.detail)
        size = t.value(.size, d.size).clamped(to: EditLimits.grainSize)
        roughness = t.value(.roughness, d.roughness).clamped(to: EditLimits.detail)
    }
}

struct LensCorrection: Codable, Hashable {
    /// Use the camera's lens profile (RAW files that have one).
    var profile = true
    /// Remove purple and green fringes along high-contrast edges.
    var removeFringing = false
    /// Positive fixes barrel distortion (bulging), negative fixes pincushion.
    var distortion: Double = 0
    /// Positive brightens dark corners, negative darkens them.
    var vignetting: Double = 0

    var isGeometryNeutral: Bool { distortion == 0 && vignetting == 0 && !removeFringing }

    init() {}

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        let d = LensCorrection()
        profile = t.value(.profile, d.profile)
        removeFringing = t.value(.removeFringing, d.removeFringing)
        distortion = t.value(.distortion, d.distortion).clamped(to: EditLimits.slider)
        vignetting = t.value(.vignetting, d.vignetting).clamped(to: EditLimits.slider)
    }
}

// MARK: - Spot removal

/// One removed spot: the area at `center` is replaced with the area at `source`, blended to
/// match its surroundings. Normalized to the oriented, uncropped image, like masks; `radius` is
/// a fraction of its long edge.
struct Spot: Codable, Hashable, Identifiable {
    var id = UUID()
    var center: NormPoint
    var source: NormPoint
    var radius: Double = 0.015
    /// 0 = hard edge, 1 = very soft.
    var feather: Double = 0.5

    init(id: UUID = UUID(), center: NormPoint, source: NormPoint, radius: Double = 0.015, feather: Double = 0.5) {
        self.id = id; self.center = center; self.source = source; self.radius = radius; self.feather = feather
    }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        id = t.value(.id, UUID())
        center = try t.required(.center)
        source = try t.required(.source)
        radius = t.value(.radius, 0.015).clamped(to: EditLimits.spotRadius)
        feather = t.value(.feather, 0.5).clamped(to: EditLimits.unit)
    }
}

// MARK: - Masks

struct NormPoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        x = try t.required(.x, as: Double.self).clamped(to: EditLimits.coordinate)
        y = try t.required(.y, as: Double.self).clamped(to: EditLimits.coordinate)
    }
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
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0

    var isNeutral: Bool { self == LocalAdjustments() }

    init() {}

    // Tolerant decoding: a missing field keeps its default instead of dropping the whole set.
    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        func v(_ key: CodingKeys) -> Double { t.value(key, 0) }
        exposure = v(.exposure); contrast = v(.contrast); highlights = v(.highlights); shadows = v(.shadows)
        whites = v(.whites); blacks = v(.blacks); temperature = v(.temperature); tint = v(.tint)
        vibrance = v(.vibrance); saturation = v(.saturation)
        texture = v(.texture); clarity = v(.clarity); dehaze = v(.dehaze)
    }
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

    init(points: [NormPoint] = [], radius: Double = 0.04, feather: Double = 0.6, flow: Double = 1, erase: Bool = false) {
        self.points = points; self.radius = radius; self.feather = feather; self.flow = flow; self.erase = erase
    }

    // Tolerant decoding: a missing field keeps its default; a bad point drops only that point.
    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        let d = BrushStroke()
        points = t.array(.points, default: [], limit: EditLimits.pointsPerStroke)
        radius = t.value(.radius, d.radius).clamped(to: EditLimits.brushRadius)
        feather = t.value(.feather, d.feather).clamped(to: EditLimits.unit)
        flow = t.value(.flow, d.flow).clamped(to: EditLimits.unit)
        erase = t.value(.erase, d.erase)
    }
}

enum ShapeKind: String, Codable { case linear, radial }

/// Limits a mask to a band of brightness or to colors near a picked one.
struct MaskRange: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable { case luminance, color }
    var kind: Kind = .luminance
    /// Luminance band, 0...1 (display brightness).
    var low: Double = 0
    var high: Double = 1
    /// Soft edge of the band, 0...1.
    var smoothness: Double = 0.15
    /// Picked color (display RGB, 0...1) and how far from it still counts, 0...100.
    var red: Double = 0.5
    var green: Double = 0.5
    var blue: Double = 0.5
    var tolerance: Double = 30

    var isNeutral: Bool { kind == .luminance && low <= 0 && high >= 1 }

    init(kind: Kind = .luminance) { self.kind = kind }

    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        let d = MaskRange()
        kind = t.value(.kind, d.kind)
        low = t.value(.low, d.low).clamped(to: EditLimits.unit)
        high = t.value(.high, d.high).clamped(to: EditLimits.unit)
        smoothness = t.value(.smoothness, d.smoothness).clamped(to: EditLimits.unit)
        red = t.value(.red, d.red).clamped(to: EditLimits.unit)
        green = t.value(.green, d.green).clamped(to: EditLimits.unit)
        blue = t.value(.blue, d.blue).clamped(to: EditLimits.unit)
        tolerance = t.value(.tolerance, d.tolerance).clamped(to: EditLimits.detail)
    }
}

enum CombineMode: String, Codable, CaseIterable, Identifiable {
    case add, subtract, intersect
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .add: "plus.circle"
        case .subtract: "minus.circle"
        case .intersect: "circle.circle"
        }
    }
}

/// A gradient shape. Masks keep their own (first) shape in their fields, plus any number of
/// extra shapes combined into the mask with a mode.
struct MaskShape: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: ShapeKind
    var mode: CombineMode = .add
    var center = NormPoint(x: 0.5, y: 0.5)
    var radiusX = 0.25
    var radiusY = 0.25
    var feather = 0.5
    var start = NormPoint(x: 0.5, y: 0.25)
    var end = NormPoint(x: 0.5, y: 0.6)

    init(id: UUID = UUID(), kind: ShapeKind, mode: CombineMode = .add, center: NormPoint = NormPoint(x: 0.5, y: 0.5),
         radiusX: Double = 0.25, radiusY: Double = 0.25, feather: Double = 0.5,
         start: NormPoint = NormPoint(x: 0.5, y: 0.25), end: NormPoint = NormPoint(x: 0.5, y: 0.6)) {
        self.id = id; self.kind = kind; self.mode = mode; self.center = center
        self.radiusX = radiusX; self.radiusY = radiusY; self.feather = feather; self.start = start; self.end = end
    }

    // Tolerant decoding: only `kind` is needed (a shape of an unknown kind is dropped).
    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        let d = MaskShape(kind: .radial)
        id = t.value(.id, UUID())
        kind = try t.required(.kind)
        mode = t.value(.mode, d.mode)
        center = t.value(.center, d.center)
        radiusX = t.value(.radiusX, d.radiusX).clamped(to: EditLimits.shapeRadius)
        radiusY = t.value(.radiusY, d.radiusY).clamped(to: EditLimits.shapeRadius)
        feather = t.value(.feather, d.feather).clamped(to: EditLimits.unit)
        start = t.value(.start, d.start)
        end = t.value(.end, d.end)
    }
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
    /// Brush masks: the mask itself. Other kinds: add/subtract refinements painted on top.
    var strokes: [BrushStroke] = []
    /// Extra linear/radial shapes combined into this mask, in order.
    var shapes: [MaskShape] = []
    // Subject: which detected subjects to include (1-based); nil = all of them.
    var subjects: [Int]?
    // Automatic masks: expand (+) or shrink (-) the edge, -100...100; and soften it, 0...100.
    var grow: Double = 0
    var softness: Double = 0
    /// Narrows the mask to a brightness band or a color; nil = no limit.
    var range: MaskRange?

    var local = LocalAdjustments()

    init(name: String, kind: MaskKind) {
        self.name = name
        self.kind = kind
    }

    /// Everything that shapes the mask (not what it does), for caching.
    var shapeKey: Int {
        var h = Hasher()
        h.combine(kind); h.combine(invert); h.combine(center); h.combine(radiusX); h.combine(radiusY)
        h.combine(feather); h.combine(start); h.combine(end); h.combine(strokes); h.combine(subjects)
        h.combine(grow); h.combine(softness); h.combine(shapes)
        // `range` is left out on purpose: it depends on the pixels under the mask, so it's applied after caching.
        return h.finalize()
    }

    /// The mask's own shape (only for linear and radial masks).
    var mainShape: MaskShape? {
        let k: ShapeKind
        switch kind {
        case .linear: k = .linear
        case .radial: k = .radial
        default: return nil
        }
        return MaskShape(id: id, kind: k, center: center, radiusX: radiusX, radiusY: radiusY, feather: feather, start: start, end: end)
    }

    /// The shape with this id: the mask's own (id == mask id) or one of the extras.
    func shape(_ shapeID: UUID?) -> MaskShape? {
        guard let shapeID, shapeID != id else { return mainShape }
        return shapes.first { $0.id == shapeID }
    }

    mutating func editShape(_ shapeID: UUID?, _ change: (inout MaskShape) -> Void) {
        if let shapeID, shapeID != id {
            guard let i = shapes.firstIndex(where: { $0.id == shapeID }) else { return }
            change(&shapes[i])
        } else if var s = mainShape {
            change(&s)
            center = s.center; radiusX = s.radiusX; radiusY = s.radiusY; feather = s.feather; start = s.start; end = s.end
        }
    }

    // Tolerant decoding: older sidecars lack the newer fields.
    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        let d = Mask(name: "", kind: .radial)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { t.value(key, fallback) }
        id = v(.id, UUID())
        name = v(.name, "Mask")
        kind = v(.kind, .radial)
        enabled = v(.enabled, d.enabled)
        invert = v(.invert, d.invert)
        center = v(.center, d.center)
        radiusX = v(.radiusX, d.radiusX).clamped(to: EditLimits.shapeRadius)
        radiusY = v(.radiusY, d.radiusY).clamped(to: EditLimits.shapeRadius)
        feather = v(.feather, d.feather).clamped(to: EditLimits.unit)
        start = v(.start, d.start)
        end = v(.end, d.end)
        strokes = t.array(.strokes, default: d.strokes, limit: EditLimits.strokesPerMask)
        shapes = t.array(.shapes, default: d.shapes, limit: EditLimits.shapesPerMask)
        subjects = t.array(.subjects, of: Int.self)
        grow = v(.grow, d.grow).clamped(to: EditLimits.grow)
        softness = v(.softness, d.softness).clamped(to: EditLimits.softness)
        range = t.optional(.range, as: MaskRange.self)
        local = v(.local, d.local)
    }
}

/// Every non-destructive edit applied to a photo. Most sliders run -100...100 around a neutral 0.
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
    var grain = Grain()
    var sharpening: Double = 0     // 0...100
    var noiseReduction: Double = 0 // 0...100
    // Presence, -100...100
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    // Curves & HSL
    var curve: [CurvePoint] = Adjustments.identityCurve
    var curveRed: [CurvePoint] = Adjustments.identityCurve
    var curveGreen: [CurvePoint] = Adjustments.identityCurve
    var curveBlue: [CurvePoint] = Adjustments.identityCurve
    var parametric = ParametricCurve()
    var hsl: [HSLBand] = Array(repeating: HSLBand(), count: HSLColor.allCases.count)
    var hueCurves = HueCurves()
    // Color grading wheels
    var grading = ColorGrading()
    // Local adjustments
    var masks: [Mask] = []
    // Retouching
    var spots: [Spot] = []
    // Lens and geometry
    var lens = LensCorrection()
    var crop = CropSettings()

    static let identityCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    init() {}

    var isDefault: Bool { self == Adjustments() }

    /// Every tone curve (point curves for all channels and the region sliders) is flat.
    var curveIsIdentity: Bool {
        curve == Adjustments.identityCurve && curveRed == Adjustments.identityCurve
            && curveGreen == Adjustments.identityCurve && curveBlue == Adjustments.identityCurve && parametric.isNeutral
    }

    mutating func resetCurves() {
        let d = Adjustments()
        curve = d.curve; curveRed = d.curveRed; curveGreen = d.curveGreen; curveBlue = d.curveBlue; parametric = d.parametric
    }

    /// Everything except crop — what copy/paste carries over.
    func withCrop(from other: Adjustments) -> Adjustments {
        var copy = self
        copy.crop = other.crop
        return copy
    }

    /// These adjustments with the chosen groups taken from `source` (selective paste).
    func copying(_ groups: Set<SettingsGroup>, from source: Adjustments) -> Adjustments {
        var a = self
        for g in groups {
            switch g {
            case .light:
                a.exposure = source.exposure; a.contrast = source.contrast; a.highlights = source.highlights
                a.shadows = source.shadows; a.whites = source.whites; a.blacks = source.blacks
                a.texture = source.texture; a.clarity = source.clarity; a.dehaze = source.dehaze
            case .color:
                a.temperature = source.temperature; a.tint = source.tint
                a.vibrance = source.vibrance; a.saturation = source.saturation
            case .grading: a.grading = source.grading
            case .curve:
                a.curve = source.curve; a.curveRed = source.curveRed; a.curveGreen = source.curveGreen
                a.curveBlue = source.curveBlue; a.parametric = source.parametric
            case .hsl: a.hsl = source.hsl; a.hueCurves = source.hueCurves
            case .detail: a.sharpening = source.sharpening; a.noiseReduction = source.noiseReduction
            case .effects: a.vignette = source.vignette; a.grain = source.grain
            case .lens: a.lens = source.lens
            case .masks: a.masks = source.masks
            case .spots: a.spots = source.spots
            case .crop: a.crop = source.crop
            }
        }
        return a
    }

    /// What a preset saved from these edits stores: everything but the crop, and the masks only
    /// with `includeMasks`. Subject and sky masks are detected again on each photo the preset is
    /// applied to (all subjects, since which ones were picked only makes sense on this photo);
    /// drawn masks keep their place in the frame.
    func presetLook(includeMasks: Bool) -> Adjustments {
        var look = self
        look.crop = CropSettings()
        look.masks = includeMasks ? masks.map { mask in
            var m = mask
            if m.kind == .subject { m.subjects = nil }
            return m
        } : []
        return look
    }

    /// What a preset carries over: the global look, plus the preset's own masks (when it was saved
    /// with them), added after the target's. The target keeps its crop, its masks and its removed spots.
    func asPreset(onto other: Adjustments) -> Adjustments {
        var copy = self
        copy.crop = other.crop
        copy.masks = other.masks + masks.map { mask in
            var m = mask
            m.id = UUID()   // applying the preset twice gives two masks, not one id twice
            return m
        }
        copy.spots = other.spots
        return copy
    }

    // Tolerant decoding so sidecars and presets survive new fields being added.
    init(from decoder: Decoder) throws {
        let t = try TolerantContainer(decoder, keyedBy: CodingKeys.self)
        let d = Adjustments()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { t.value(key, fallback) }
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
        grain = v(.grain, d.grain)
        sharpening = v(.sharpening, d.sharpening)
        noiseReduction = v(.noiseReduction, d.noiseReduction)
        texture = v(.texture, d.texture).clamped(to: EditLimits.slider)
        clarity = v(.clarity, d.clarity).clamped(to: EditLimits.slider)
        dehaze = v(.dehaze, d.dehaze).clamped(to: EditLimits.slider)
        // Per point and per mask: one bad entry doesn't reset the rest.
        func curve(_ key: CodingKeys) -> [CurvePoint] {
            let points: [CurvePoint] = t.array(key, default: Adjustments.identityCurve, limit: EditLimits.curvePoints)
            if points.count >= 2 { return points }
            if t.c.contains(key) { t.noteDropped() }
            return Adjustments.identityCurve
        }
        self.curve = curve(.curve)
        curveRed = curve(.curveRed)
        curveGreen = curve(.curveGreen)
        curveBlue = curve(.curveBlue)
        parametric = v(.parametric, d.parametric)
        hueCurves = v(.hueCurves, d.hueCurves)
        var bands = v(.hsl, d.hsl)
        if bands.count != HSLColor.allCases.count {
            t.noteDropped()
            bands = d.hsl
        }
        hsl = bands
        grading = v(.grading, d.grading)
        masks = t.array(.masks, default: d.masks, limit: EditLimits.masks)
        spots = t.array(.spots, default: d.spots, limit: EditLimits.spots)
        lens = v(.lens, d.lens)
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
    var curveRed: [CurvePoint]
    var curveGreen: [CurvePoint]
    var curveBlue: [CurvePoint]
    var parametric: ParametricCurve
    var hsl: [HSLBand]
    var hueCurves: HueCurves
    var grading: ColorGrading

    init(_ a: Adjustments) {
        contrast = a.contrast
        highlights = max(0, a.highlights)
        whites = a.whites
        blacks = a.blacks
        curve = a.curve
        curveRed = a.curveRed
        curveGreen = a.curveGreen
        curveBlue = a.curveBlue
        parametric = a.parametric
        hsl = a.hsl
        hueCurves = a.hueCurves
        grading = a.grading
    }

    /// Tone-only key for a mask's local contrast / whites / blacks.
    init(local l: LocalAdjustments) {
        contrast = l.contrast
        highlights = max(0, l.highlights)
        whites = l.whites
        blacks = l.blacks
        curve = Adjustments.identityCurve
        curveRed = Adjustments.identityCurve
        curveGreen = Adjustments.identityCurve
        curveBlue = Adjustments.identityCurve
        parametric = ParametricCurve()
        hsl = Array(repeating: HSLBand(), count: HSLColor.allCases.count)
        hueCurves = HueCurves()
        grading = ColorGrading()
    }

    var channelCurvesAreIdentity: Bool {
        curveRed == Adjustments.identityCurve && curveGreen == Adjustments.identityCurve && curveBlue == Adjustments.identityCurve
    }

    var isIdentity: Bool {
        contrast == 0 && highlights == 0 && whites == 0 && blacks == 0
            && curve == Adjustments.identityCurve && channelCurvesAreIdentity && parametric.isNeutral
            && hsl.allSatisfy(\.isNeutral) && hueCurves.isNeutral && grading.isNeutral
    }
}

/// Groups of settings that can be pasted on their own. Together they cover every field of `Adjustments`.
enum SettingsGroup: String, CaseIterable, Identifiable, Codable {
    case light, color, grading, curve, hsl, detail, effects, lens, masks, spots, crop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: "Light (exposure, contrast, highlights, shadows, whites, blacks, texture, clarity, dehaze)"
        case .color: "Color (white balance, vibrance, saturation)"
        case .grading: "Color grading"
        case .curve: "Tone curve"
        case .hsl: "HSL and hue curves"
        case .detail: "Detail (sharpening, noise reduction)"
        case .effects: "Effects (vignette, grain)"
        case .lens: "Lens corrections"
        case .masks: "Masks"
        case .spots: "Removed spots"
        case .crop: "Crop & straighten"
        }
    }
    /// What a plain paste carries: everything but the crop and removed spots (both belong to one frame).
    static let standard = Set(allCases).subtracting([.crop, .spots])
}
