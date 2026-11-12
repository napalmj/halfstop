import SwiftUI

private struct ThumbKey: Equatable {
    let url: URL
    let adjustments: Adjustments
}

/// Async thumbnail that reflects edits (debounced so slider drags don't flood the queue).
struct ThumbnailView: View {
    let photo: Photo
    var maxSize: CGFloat = 400
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(Theme.panelRaised)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: ThumbKey(url: photo.url, adjustments: photo.adjustments)) {
            let url = photo.url, adj = photo.adjustments
            if let hit = ThumbnailService.shared.cached(url: url, adjustments: adj) {
                image = hit
                return
            }
            if image != nil {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            let result = await ThumbnailService.shared.image(url: url, adjustments: adj)
            if !Task.isCancelled, let result { image = result }
        }
    }
}

struct StarsBadge: View {
    let rating: Int
    var size: CGFloat = 9

    var body: some View {
        if rating > 0 {
            HStack(spacing: 1) {
                ForEach(0..<rating, id: \.self) { _ in
                    Image(systemName: "star.fill").font(.system(size: size))
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 1.5)
            .padding(4)
        }
    }
}

struct FlagBadge: View {
    let flag: Flag

    var body: some View {
        switch flag {
        case .pick:
            Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 1.5).padding(5)
        case .reject:
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 1.5).padding(5)
        case .none:
            EmptyView()
        }
    }
}

/// Hue/strength wheel: angle picks the hue, distance from center the strength.
struct ColorWheel: View {
    let title: String
    let wheel: GradeWheel
    var diameter: CGFloat = 76
    let onBegin: () -> Void
    let onChange: (GradeWheel) -> Void

    @State private var dragging = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(AngularGradient(
                    colors: stride(from: 0.0, through: 360.0, by: 30).map { Color(hue: $0 / 360, saturation: 0.8, brightness: 0.85) },
                    center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)],
                                             center: .center, startRadius: 0, endRadius: diameter * 0.5))
                Circle().stroke(Theme.hairline)
                let r = wheel.saturation / 100 * diameter / 2
                let a = wheel.hue * .pi / 180
                Circle()
                    .stroke(.white, lineWidth: 2)
                    .background(Circle().fill(.black.opacity(0.3)))
                    .frame(width: dragging ? 13 : 11, height: dragging ? 13 : 11)
                    .offset(x: r * cos(a), y: r * sin(a))
                    .shadow(color: .black.opacity(0.5), radius: 1)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; onBegin() }
                    let dx = g.location.x - diameter / 2, dy = g.location.y - diameter / 2
                    var w = wheel
                    var hue = atan2(dy, dx) * 180 / .pi
                    if hue < 0 { hue += 360 }
                    w.hue = hue.rounded()
                    w.saturation = (min(1, hypot(dx, dy) / (diameter / 2)) * 100).rounded()
                    onChange(w)
                }
                .onEnded { _ in dragging = false })

            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(wheel.isNeutral ? Theme.secondary : Theme.text)
                .onTapGesture(count: 2) {
                    onBegin()
                    var w = wheel
                    w.saturation = 0
                    w.luminance = 0
                    onChange(w)
                }
                .help("Double-click to reset")
        }
    }
}
