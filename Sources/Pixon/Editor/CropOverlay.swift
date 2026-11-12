import SwiftUI

/// Interactive crop rectangle drawn over the straightened image.
struct CropOverlay: View {
    /// Where the straightened image sits in this view (points).
    let imageRect: CGRect
    let crop: NormRect
    /// Desired width/height in pixels, nil for free.
    let ratio: Double?
    let onBegin: () -> Void
    let onChange: (NormRect) -> Void

    private enum Handle { case move, tl, t, tr, r, br, b, bl, l }

    @State private var active: Handle?
    @State private var startRect = NormRect.full

    var body: some View {
        let r = viewRect(crop)
        Canvas { ctx, size in
            var dim = Path(CGRect(origin: .zero, size: size))
            dim.addRect(r)
            ctx.fill(dim, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))

            // Thirds.
            var grid = Path()
            for i in 1..<3 {
                let t = CGFloat(i) / 3
                grid.move(to: CGPoint(x: r.minX + r.width * t, y: r.minY)); grid.addLine(to: CGPoint(x: r.minX + r.width * t, y: r.maxY))
                grid.move(to: CGPoint(x: r.minX, y: r.minY + r.height * t)); grid.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * t))
            }
            ctx.stroke(grid, with: .color(.white.opacity(active == nil ? 0.25 : 0.5)), lineWidth: 0.5)
            ctx.stroke(Path(r), with: .color(.white.opacity(0.9)), lineWidth: 1)

            // Corner handles.
            let L: CGFloat = 16, w: CGFloat = 3
            var h = Path()
            for (p, sx, sy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0)] {
                h.addRect(CGRect(x: sx > 0 ? p.x - w : p.x - L + w, y: sy > 0 ? p.y - w : p.y, width: L, height: w))
                h.addRect(CGRect(x: sx > 0 ? p.x - w : p.x, y: sy > 0 ? p.y - w : p.y - L + w, width: w, height: L))
            }
            // Edge handles.
            h.addRect(CGRect(x: r.midX - 10, y: r.minY - w, width: 20, height: w))
            h.addRect(CGRect(x: r.midX - 10, y: r.maxY, width: 20, height: w))
            h.addRect(CGRect(x: r.minX - w, y: r.midY - 10, width: w, height: 20))
            h.addRect(CGRect(x: r.maxX, y: r.midY - 10, width: w, height: 20))
            ctx.fill(h, with: .color(.white))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if active == nil {
                        guard let handle = hitTest(g.startLocation, r) else { return }
                        active = handle
                        startRect = crop
                        onBegin()
                    }
                    guard let active else { return }
                    let dx = Double(g.translation.width / imageRect.width)
                    let dy = Double(g.translation.height / imageRect.height)
                    onChange(resize(startRect, handle: active, dx: dx, dy: dy))
                }
                .onEnded { _ in active = nil }
        )
    }

    private func viewRect(_ n: NormRect) -> CGRect {
        CGRect(x: imageRect.minX + n.x * imageRect.width, y: imageRect.minY + n.y * imageRect.height,
               width: n.width * imageRect.width, height: n.height * imageRect.height)
    }

    private func hitTest(_ p: CGPoint, _ r: CGRect) -> Handle? {
        let tol: CGFloat = 14
        let nearL = abs(p.x - r.minX) < tol, nearR = abs(p.x - r.maxX) < tol
        let nearT = abs(p.y - r.minY) < tol, nearB = abs(p.y - r.maxY) < tol
        let inX = p.x > r.minX - tol && p.x < r.maxX + tol
        let inY = p.y > r.minY - tol && p.y < r.maxY + tol
        if nearL && nearT { return .tl }
        if nearR && nearT { return .tr }
        if nearR && nearB { return .br }
        if nearL && nearB { return .bl }
        if nearT && inX { return .t }
        if nearB && inX { return .b }
        if nearL && inY { return .l }
        if nearR && inY { return .r }
        if r.contains(p) { return .move }
        return nil
    }

    private func resize(_ s: NormRect, handle: Handle, dx: Double, dy: Double) -> NormRect {
        let minSize = 0.04
        if handle == .move {
            var n = s
            n.x = min(max(s.x + dx, 0), 1 - s.width)
            n.y = min(max(s.y + dy, 0), 1 - s.height)
            return n
        }
        // Normalized-space aspect (width_n / height_n) for the requested pixel ratio.
        let frameAspect = Double(imageRect.width / max(imageRect.height, 1))
        let rn = ratio.map { $0 / frameAspect }

        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        switch handle {
        case .l, .tl, .bl: minX = min(max(s.minX + dx, 0), maxX - minSize)
        case .r, .tr, .br: maxX = max(min(s.maxX + dx, 1), minX + minSize)
        default: break
        }
        switch handle {
        case .t, .tl, .tr: minY = min(max(s.minY + dy, 0), maxY - minSize)
        case .b, .bl, .br: maxY = max(min(s.maxY + dy, 1), minY + minSize)
        default: break
        }
        guard let rn else { return NormRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }

        switch handle {
        case .tl, .tr, .bl, .br:
            // Anchor the opposite corner; width drives height.
            let anchorX = (handle == .tl || handle == .bl) ? s.maxX : s.minX
            let anchorY = (handle == .tl || handle == .tr) ? s.maxY : s.minY
            let growsLeft = handle == .tl || handle == .bl
            let growsUp = handle == .tl || handle == .tr
            var w = max(maxX - minX, (maxY - minY) * rn)
            let maxW = growsLeft ? anchorX : 1 - anchorX
            let maxH = growsUp ? anchorY : 1 - anchorY
            w = min(w, maxW, maxH * rn)
            let h = w / rn
            return NormRect(x: growsLeft ? anchorX - w : anchorX, y: growsUp ? anchorY - h : anchorY, width: w, height: h)
        case .l, .r:
            let cy = s.y + s.height / 2
            var w = maxX - minX
            let maxH = 2 * min(cy, 1 - cy)
            w = min(w, maxH * rn)
            let h = w / rn
            let x = handle == .l ? s.maxX - w : s.minX
            return NormRect(x: x, y: cy - h / 2, width: w, height: h)
        case .t, .b:
            let cx = s.x + s.width / 2
            var h = maxY - minY
            let maxW = 2 * min(cx, 1 - cx)
            h = min(h, maxW / rn)
            let w = h * rn
            let y = handle == .t ? s.maxY - h : s.minY
            return NormRect(x: cx - w / 2, y: y, width: w, height: h)
        case .move:
            return s
        }
    }

    /// Largest rect with the given pixel ratio, centered on `around`, inside the frame.
    static func fitted(ratio: Double?, around current: NormRect, frameSize: CGSize) -> NormRect {
        guard let ratio else { return current }
        let rn = ratio / Double(frameSize.width / max(frameSize.height, 1))
        let cx = current.x + current.width / 2, cy = current.y + current.height / 2
        // Start from the biggest possible rect at this ratio, then fit around the center.
        var w = min(1, rn), h = w / rn
        if h > 1 { h = 1; w = rn }
        let x = min(max(cx - w / 2, 0), 1 - w)
        let y = min(max(cy - h / 2, 0), 1 - h)
        return NormRect(x: x, y: y, width: w, height: h)
    }
}
