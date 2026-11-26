import Foundation
import CoreGraphics

/// Spot removal, target adjust and mask ranges: the editing actions behind the photo tools.
extension LibraryStore {

    // MARK: Spots

    var activeSpot: Spot? {
        guard let id = activeSpotID else { return nil }
        return current?.adjustments.spots.first { $0.id == id }
    }

    func addSpot(center: NormPoint, source: NormPoint) {
        checkpoint()
        let spot = Spot(center: center, source: source, radius: spotSize)
        edit { $0.spots.append(spot) }
        activeSpotID = spot.id
    }

    func editSpot(_ id: UUID, _ change: (inout Spot) -> Void) {
        edit { a in
            guard let i = a.spots.firstIndex(where: { $0.id == id }) else { return }
            change(&a.spots[i])
        }
    }

    func deleteSpot(_ id: UUID) {
        checkpoint()
        edit { $0.spots.removeAll { $0.id == id } }
        if activeSpotID == id { activeSpotID = nil }
    }

    func clearSpots() {
        checkpoint()
        edit { $0.spots = [] }
        activeSpotID = nil
    }

    /// Resizes the selected spot, or the size new spots get when none is selected.
    func scaleSpotSize(_ factor: Double) {
        if let id = activeSpotID {
            editSpot(id) { $0.radius = ($0.radius * factor).clamped(to: EditLimits.spotRadius) }
            if let r = activeSpot?.radius { spotSize = r }
        } else {
            spotSize = (spotSize * factor).clamped(to: 0.003...0.15)
        }
    }

    // MARK: Hue curves

    /// Sets the current hue curve at `hue` (degrees) to `y` (0.5 = no change).
    func setHueCurve(at hue: Double, to y: Double, channel: HueCurveChannel? = nil) {
        let kp = (channel ?? hueCurveChannel).keyPath
        edit { a in HueCurves.setPoint(&a.hueCurves[keyPath: kp], x: hue / 360, y: y) }
    }

    // MARK: Mask ranges

    func setMaskRangeKind(_ kind: MaskRange.Kind?) {
        checkpoint()
        editMask { m in
            guard let kind else { m.range = nil; return }
            var r = m.range ?? MaskRange(kind: kind)
            r.kind = kind
            m.range = r
        }
        // Choosing Color starts the eyedropper right away.
        pickingRangeColor = kind == .color
    }

    func pickRangeColor(_ rgb: SIMD3<Float>) {
        pickingRangeColor = false
        checkpoint()
        editMask { m in
            var r = m.range ?? MaskRange(kind: .color)
            r.kind = .color
            r.red = Double(rgb.x); r.green = Double(rgb.y); r.blue = Double(rgb.z)
            m.range = r
        }
    }
}
