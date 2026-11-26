import SwiftUI

/// A curve over the color wheel: hues run left to right (wrapping at the ends), the middle line
/// is "no change". Drag on empty space to add a point (with neutral anchors on both sides, so only
/// nearby colors move), drag a point to move it, drag it off the graph to remove it.
struct HueCurveEditor: View {
    let points: [CurvePoint]
    let channel: HueCurveChannel
    let onBegin: () -> Void
    let onChange: ([CurvePoint]) -> Void

    @State private var dragIndex: Int?
    @State private var working: [CurvePoint] = []
    @State private var removing = false

    private let stripHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, size in
                let graph = CGSize(width: size.width, height: size.height - stripHeight)
                // Hue strip along the bottom.
                let steps = 72
                for i in 0..<steps {
                    let x0 = CGFloat(i) / CGFloat(steps) * size.width
                    let rect = CGRect(x: x0, y: graph.height, width: size.width / CGFloat(steps) + 0.5, height: stripHeight)
                    ctx.fill(Path(rect), with: .color(Color(hue: Double(i) / Double(steps), saturation: 0.75, brightness: 0.9)))
                }
                // Neutral line and quarter grid.
                var grid = Path()
                for i in 1..<4 {
                    let x = CGFloat(i) / 4 * size.width
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: graph.height))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 1)
                var mid = Path()
                mid.move(to: CGPoint(x: 0, y: graph.height / 2)); mid.addLine(to: CGPoint(x: size.width, y: graph.height / 2))
                ctx.stroke(mid, with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                let shown = displayPoints
                let curve = PeriodicCurve(points: shown)
                var path = Path()
                for s in 0...180 {
                    let x = Double(s) / 180
                    let p = CGPoint(x: x * graph.width, y: (1 - curve.evaluate(x)) * graph.height)
                    s == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                ctx.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                for (i, p) in shown.enumerated() {
                    let c = CGPoint(x: p.x * graph.width, y: (1 - p.y) * graph.height)
                    let r: CGFloat = i == dragIndex ? 5 : 4
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                    let fill = i == dragIndex && removing ? Color.red : Color(hue: p.x, saturation: 0.7, brightness: 1)
                    ctx.fill(Path(ellipseIn: rect), with: .color(fill))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.5)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in drag(g, size: CGSize(width: size.width, height: size.height - stripHeight)) }
                .onEnded { _ in endDrag() })
        }
        .frame(height: 120)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
        .help(help)
    }

    private var help: String {
        switch channel {
        case .hue: "Up shifts a color toward the next hue to the right, down toward the left."
        case .saturation: "Up makes a color more saturated, down takes it toward gray."
        case .luminance: "Up brightens a color, down darkens it."
        }
    }

    private var displayPoints: [CurvePoint] {
        guard dragIndex != nil else { return points }
        var pts = working
        if removing, let i = dragIndex { pts.remove(at: i) }
        return pts
    }

    private func drag(_ g: DragGesture.Value, size: CGSize) {
        func norm(_ p: CGPoint) -> (Double, Double) { (Double(p.x / size.width), Double(1 - p.y / size.height)) }
        if dragIndex == nil {
            working = points.sorted { $0.x < $1.x }
            onBegin()
            let start = g.startLocation
            let hit = working.indices.min { a, b in dist(working[a], start, size) < dist(working[b], start, size) }
            if let hit, dist(working[hit], start, size) < 12 {
                dragIndex = hit
            } else {
                let (x, y) = norm(start)
                dragIndex = HueCurves.setPoint(&working, x: min(max(x, 0), 0.999), y: y, near: 0)
            }
        }
        guard let i = dragIndex else { return }
        let (x, y) = norm(g.location)
        removing = y < -0.15 || y > 1.15
        working[i] = CurvePoint(x: min(max(x, 0), 0.999), y: min(max(y, 0), 1))
        onChange(displayPoints)
    }

    private func endDrag() {
        onChange(displayPoints.sorted { $0.x < $1.x })
        dragIndex = nil
        removing = false
    }

    private func dist(_ p: CurvePoint, _ loc: CGPoint, _ size: CGSize) -> CGFloat {
        hypot(p.x * size.width - loc.x, (1 - p.y) * size.height - loc.y)
    }
}

/// The parametric tone curve: the curve the four region sliders make, with the three splits
/// between regions as handles along the bottom.
struct ParametricCurveView: View {
    let parametric: ParametricCurve
    let histogram: HistogramData?
    let onBegin: () -> Void
    let onChange: (ParametricCurve) -> Void

    @State private var dragging: Int?
    private let stripHeight: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let graph = CGSize(width: size.width, height: size.height - stripHeight)
            let splits = [parametric.split1, parametric.split2, parametric.split3]
            Canvas { ctx, _ in
                if let h = histogram {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: graph.height))
                    for i in 0..<h.red.count {
                        let v = (h.red[i] + h.green[i] + h.blue[i]) / 3
                        path.addLine(to: CGPoint(x: CGFloat(i) / CGFloat(h.red.count - 1) * graph.width,
                                                 y: graph.height - CGFloat(v) * graph.height * 0.9))
                    }
                    path.addLine(to: CGPoint(x: graph.width, y: graph.height))
                    ctx.fill(path, with: .color(.white.opacity(0.06)))
                }
                // Region boundaries.
                for s in splits {
                    var line = Path()
                    line.move(to: CGPoint(x: s * graph.width, y: 0)); line.addLine(to: CGPoint(x: s * graph.width, y: graph.height))
                    ctx.stroke(line, with: .color(.white.opacity(0.1)), lineWidth: 1)
                }
                var diag = Path()
                diag.move(to: CGPoint(x: 0, y: graph.height)); diag.addLine(to: CGPoint(x: graph.width, y: 0))
                ctx.stroke(diag, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                let shape = ParametricShape(parametric)
                var path = Path()
                for i in 0...128 {
                    let x = Double(i) / 128
                    let p = CGPoint(x: x * graph.width, y: (1 - (shape?.evaluate(x) ?? x)) * graph.height)
                    i == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                ctx.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                // Split handles.
                for (i, s) in splits.enumerated() {
                    let x = s * graph.width, y = graph.height + 3
                    var tri = Path()
                    tri.move(to: CGPoint(x: x, y: y)); tri.addLine(to: CGPoint(x: x - 5, y: y + 9)); tri.addLine(to: CGPoint(x: x + 5, y: y + 9))
                    tri.closeSubpath()
                    ctx.fill(tri, with: .color(dragging == i ? Theme.accent : .white.opacity(0.7)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragging == nil {
                        // Only the strip under the graph moves splits.
                        guard g.startLocation.y > graph.height - 4 else { return }
                        let x = g.startLocation.x / graph.width
                        dragging = splits.indices.min { abs(splits[$0] - x) < abs(splits[$1] - x) }
                        onBegin()
                    }
                    guard let i = dragging else { return }
                    var s = splits
                    let lo = i == 0 ? 0.05 : s[i - 1] + 0.05, hi = i == 2 ? 0.95 : s[i + 1] - 0.05
                    s[i] = min(max(Double(g.location.x / graph.width), lo), hi)
                    var p = parametric
                    p.split1 = s[0]; p.split2 = s[1]; p.split3 = s[2]
                    onChange(p)
                }
                .onEnded { _ in dragging = nil })
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
        .help("Drag the markers under the graph to move where the regions meet.")
    }
}
