import SwiftUI

struct HistogramView: View {
    let data: HistogramData?

    var body: some View {
        Canvas { ctx, size in
            guard let data else { return }
            ctx.blendMode = .plusLighter
            for (channel, color) in [(data.red, Color(red: 1, green: 0.25, blue: 0.25)),
                                     (data.green, Color(red: 0.25, green: 0.9, blue: 0.3)),
                                     (data.blue, Color(red: 0.3, green: 0.45, blue: 1))] {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                let n = channel.count
                for (i, v) in channel.enumerated() {
                    let x = CGFloat(i) / CGFloat(n - 1) * size.width
                    path.addLine(to: CGPoint(x: x, y: size.height - CGFloat(v) * size.height * 0.95))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(color.opacity(0.55)))
            }
            ctx.blendMode = .normal
            // Clipping warnings.
            let warn = Float(0.01)
            if data.clippedShadows > warn {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: 3, height: size.height)), with: .color(.blue.opacity(0.9)))
            }
            if data.clippedHighlights > warn {
                ctx.fill(Path(CGRect(x: size.width - 3, y: 0, width: 3, height: size.height)), with: .color(.red.opacity(0.9)))
            }
        }
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
        .animation(.easeOut(duration: 0.12), value: data)
    }
}
