import SwiftUI

/// Point curve: drag on empty space to add a point, drag a point to move it,
/// drag a point off the graph to remove it.
struct CurveEditor: View {
    let points: [CurvePoint]
    let histogram: HistogramData?
    let onBegin: () -> Void
    let onChange: ([CurvePoint]) -> Void

    @State private var dragIndex: Int?
    @State private var working: [CurvePoint] = []
    @State private var removing = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, size in
                // Luminance-ish histogram behind the curve.
                if let h = histogram {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for i in 0..<h.red.count {
                        let v = (h.red[i] + h.green[i] + h.blue[i]) / 3
                        path.addLine(to: CGPoint(x: CGFloat(i) / CGFloat(h.red.count - 1) * size.width,
                                                 y: size.height - CGFloat(v) * size.height * 0.9))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    ctx.fill(path, with: .color(.white.opacity(0.06)))
                }
                // Grid.
                var grid = Path()
                for i in 1..<4 {
                    let t = CGFloat(i) / 4
                    grid.move(to: CGPoint(x: t * size.width, y: 0)); grid.addLine(to: CGPoint(x: t * size.width, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: t * size.height)); grid.addLine(to: CGPoint(x: size.width, y: t * size.height))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
                var diag = Path()
                diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
                ctx.stroke(diag, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // Curve.
                let shown = displayPoints
                let curve = MonotoneCurve(points: shown)
                var path = Path()
                let steps = 128
                for s in 0...steps {
                    let x = Double(s) / Double(steps)
                    let y = min(max(curve.evaluate(x), 0), 1)
                    let p = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                    s == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                ctx.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)

                for (i, p) in shown.enumerated() {
                    let c = CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
                    let r: CGFloat = i == dragIndex ? 5 : 4
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(i == dragIndex ? (removing ? .red : Theme.accent) : .white))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in drag(g, size: size) }
                    .onEnded { _ in endDrag() }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
    }

    private var displayPoints: [CurvePoint] {
        guard dragIndex != nil else { return points }
        var pts = working
        if removing, let i = dragIndex { pts.remove(at: i) }
        return pts
    }

    private func normalized(_ p: CGPoint, _ size: CGSize) -> CurvePoint {
        CurvePoint(x: Double(p.x / size.width), y: Double(1 - p.y / size.height))
    }

    private func drag(_ g: DragGesture.Value, size: CGSize) {
        if dragIndex == nil {
            working = points.sorted { $0.x < $1.x }
            let start = g.startLocation
            let hit = working.enumerated().min { a, b in
                dist(a.element, start, size) < dist(b.element, start, size)
            }
            onBegin()
            if let hit, dist(hit.element, start, size) < 12 {
                dragIndex = hit.offset
            } else {
                let np = normalized(start, size)
                let insertAt = working.firstIndex { $0.x > np.x } ?? working.count
                working.insert(CurvePoint(x: min(max(np.x, 0), 1), y: min(max(np.y, 0), 1)), at: insertAt)
                dragIndex = insertAt
            }
        }
        guard let i = dragIndex else { return }
        let np = normalized(g.location, size)
        let isEndpoint = i == 0 || i == working.count - 1
        removing = !isEndpoint && (np.y < -0.12 || np.y > 1.12 || np.x < -0.12 || np.x > 1.12)
        let lo = i > 0 ? working[i - 1].x + 0.01 : 0
        let hi = i < working.count - 1 ? working[i + 1].x - 0.01 : 1
        working[i] = CurvePoint(x: min(max(np.x, lo), hi), y: min(max(np.y, 0), 1))
        onChange(displayPoints)
    }

    private func endDrag() {
        onChange(displayPoints)
        dragIndex = nil
        removing = false
    }

    private func dist(_ p: CurvePoint, _ loc: CGPoint, _ size: CGSize) -> CGFloat {
        hypot(p.x * size.width - loc.x, (1 - p.y) * size.height - loc.y)
    }
}
