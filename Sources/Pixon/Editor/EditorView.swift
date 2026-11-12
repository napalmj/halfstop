import SwiftUI

struct EditorView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PreviewArea()
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Filmstrip()
                    .frame(height: 78)
            }
            Rectangle().fill(Theme.hairline).frame(width: 1)
            AdjustPanel()
                .frame(width: 292)
        }
    }
}

private struct PreviewToken: Hashable {
    let url: URL
    let adjustments: Adjustments
    let geometry: String
    let overlay: UUID?
    let generation: Int
}

struct PreviewArea: View {
    @Environment(LibraryStore.self) private var store
    @Environment(PreviewRenderer.self) private var renderer

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.background
                if let photo = store.current {
                    content(photo, size: geo.size)
                } else {
                    Text("No photo selected").foregroundStyle(Theme.secondary)
                }
            }
        }
        .onAppear(perform: prepare)
        .onChange(of: store.currentID) { prepare() }
    }

    private var geometryMode: GeometryMode {
        if store.isCropping { return .straightenOnly }
        if store.activeMaskID != nil { return .none }
        return .full
    }

    @ViewBuilder
    private func content(_ photo: Photo, size: CGSize) -> some View {
        let url = photo.url
        let a = photo.adjustments
        let shown: Adjustments = {
            guard store.showBefore else { return a }
            var b = Adjustments()
            b.crop = a.crop
            return b
        }()
        let mode = geometryMode
        let overlayID = store.showMaskOverlay && !store.showBefore ? store.activeMaskID : nil
        let token = PreviewToken(url: url, adjustments: shown, geometry: "\(mode)", overlay: overlayID, generation: renderer.generation)

        PreviewImageView(
            token: token,
            provider: { renderer.source(for: url)?.developed(shown, geometry: mode, overlayMask: overlayID) },
            onRendered: { img in renderer.requestHistogram(img) }
        )

        if let source = renderer.source(for: url) {
            let contentSize = Self.contentSize(source.size, a, mode)
            let rect = PreviewLayout.fit(contentSize, in: size)
            if store.isCropping {
                CropOverlay(
                    imageRect: rect,
                    crop: a.crop.rect,
                    ratio: a.crop.pixelRatio(imageSize: source.size),
                    onBegin: store.checkpoint,
                    onChange: { r in store.edit { $0.crop.rect = r } }
                )
            } else if let mask = store.activeMask, !store.showBefore {
                MaskOverlay(mask: mask, imageRect: rect)
            }
        }

        VStack {
            HStack {
                if store.showBefore { badge("Before") }
                else if let mask = store.activeMask { badge("Editing \(mask.name)") }
                else if store.isCropping { badge("Crop") }
                Spacer()
                if !renderer.hasFullSource(url) {
                    ProgressView().controlSize(.small).padding(10)
                }
            }
            Spacer()
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(Theme.text)
            .padding(10)
    }

    static func contentSize(_ size: CGSize, _ a: Adjustments, _ mode: GeometryMode) -> CGSize {
        switch mode {
        case .none: return size
        case .straightenOnly: return ImageSource.straightenedFrameSize(size: size, angle: a.crop.angle)
        case .full:
            if a.crop.isIdentity { return size }
            let f = ImageSource.straightenedFrameSize(size: size, angle: a.crop.angle)
            return CGSize(width: f.width * a.crop.rect.width, height: f.height * a.crop.rect.height)
        }
    }

    private func prepare() {
        guard let url = store.currentID else { return }
        let list = store.visiblePhotos
        var neighbors: [URL] = []
        if let i = list.firstIndex(where: { $0.url == url }) {
            if i + 1 < list.count { neighbors.append(list[i + 1].url) }
            if i > 0 { neighbors.append(list[i - 1].url) }
        }
        renderer.prepare(url, neighbors: neighbors)
    }
}

// MARK: - Mask handles

/// Interactive handles for the active mask, in uncropped image space.
struct MaskOverlay: View {
    @Environment(LibraryStore.self) private var store
    let mask: Mask
    let imageRect: CGRect

    private enum Drag { case center, radiusX, radiusY, start, end, newGradient, paint }
    @State private var drag: Drag?
    @State private var hover: CGPoint?

    private func view(_ p: NormPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + p.x * imageRect.width, y: imageRect.minY + p.y * imageRect.height)
    }

    private func norm(_ p: CGPoint) -> NormPoint {
        NormPoint(x: Double((p.x - imageRect.minX) / imageRect.width), y: Double((p.y - imageRect.minY) / imageRect.height))
    }

    private var longEdge: CGFloat { max(imageRect.width, imageRect.height) }

    var body: some View {
        ZStack {
            Canvas { ctx, _ in draw(&ctx) }
                .allowsHitTesting(false)
            if mask.kind.isAutomatic {
                Color.clear
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged(changed)
                        .onEnded { _ in drag = nil })
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { hover = p } else { hover = nil }
                    }
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let white = Color.white.opacity(0.9)
        switch mask.kind {
        case .radial:
            let c = view(mask.center)
            let rx = mask.radiusX * imageRect.width, ry = mask.radiusY * imageRect.height
            let outer = CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2)
            ctx.stroke(Path(ellipseIn: outer), with: .color(white), lineWidth: 1.2)
            let k = 1 - mask.feather
            let inner = CGRect(x: c.x - rx * k, y: c.y - ry * k, width: rx * k * 2, height: ry * k * 2)
            ctx.stroke(Path(ellipseIn: inner), with: .color(white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            dot(&ctx, c, 5)
            dot(&ctx, CGPoint(x: c.x + rx, y: c.y), 4)
            dot(&ctx, CGPoint(x: c.x, y: c.y - ry), 4)
        case .linear:
            let s = view(mask.start), e = view(mask.end)
            let dx = e.x - s.x, dy = e.y - s.y
            let len = max(hypot(dx, dy), 1)
            let px = -dy / len * 4000, py = dx / len * 4000
            for (p, solid) in [(s, true), (e, false), (CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2), false)] {
                var path = Path()
                path.move(to: CGPoint(x: p.x - px, y: p.y - py))
                path.addLine(to: CGPoint(x: p.x + px, y: p.y + py))
                ctx.stroke(path, with: .color(white.opacity(solid ? 0.9 : 0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: solid ? [] : [5, 4]))
            }
            dot(&ctx, s, 5)
            dot(&ctx, e, 4)
        case .brush:
            if let hover {
                let r = store.brushSize * longEdge
                ctx.stroke(Path(ellipseIn: CGRect(x: hover.x - r, y: hover.y - r, width: r * 2, height: r * 2)),
                           with: .color(white), lineWidth: 1)
                let ri = r * (1 - store.brushFeather)
                if ri > 1 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: hover.x - ri, y: hover.y - ri, width: ri * 2, height: ri * 2)),
                               with: .color(white.opacity(0.4)), lineWidth: 1)
                }
            }
        case .subject, .sky:
            break
        }
    }

    private func dot(_ ctx: inout GraphicsContext, _ p: CGPoint, _ r: CGFloat) {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(.white))
        ctx.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.4)), lineWidth: 1)
    }

    private func changed(_ g: DragGesture.Value) {
        hover = g.location
        if drag == nil {
            drag = pick(g.startLocation)
            store.checkpoint()
            if drag == .paint {
                let stroke = BrushStroke(points: [norm(g.startLocation)], radius: store.brushSize, feather: store.brushFeather,
                                         flow: store.brushFlow, erase: store.brushErase || NSEvent.modifierFlags.contains(.option))
                store.editMask(mask.id) { $0.strokes.append(stroke) }
                return
            }
        }
        let p = norm(g.location)
        switch drag {
        case .center:
            store.editMask(mask.id) { $0.center = p }
        case .radiusX:
            store.editMask(mask.id) { $0.radiusX = max(0.01, abs(p.x - $0.center.x)) }
        case .radiusY:
            store.editMask(mask.id) { $0.radiusY = max(0.01, abs(p.y - $0.center.y)) }
        case .start:
            store.editMask(mask.id) { $0.start = p }
        case .end:
            store.editMask(mask.id) { $0.end = p }
        case .newGradient:
            let s = norm(g.startLocation)
            if hypot(g.translation.width, g.translation.height) > 4 {
                store.editMask(mask.id) { $0.start = s; $0.end = p }
            }
        case .paint:
            store.editMask(mask.id) { m in
                guard !m.strokes.isEmpty else { return }
                m.strokes[m.strokes.count - 1].points.append(p)
            }
        case nil:
            break
        }
    }

    private func pick(_ loc: CGPoint) -> Drag {
        let near: (CGPoint) -> Bool = { hypot($0.x - loc.x, $0.y - loc.y) < 14 }
        switch mask.kind {
        case .radial:
            let c = view(mask.center)
            if near(CGPoint(x: c.x + mask.radiusX * imageRect.width, y: c.y)) { return .radiusX }
            if near(CGPoint(x: c.x, y: c.y - mask.radiusY * imageRect.height)) { return .radiusY }
            return .center
        case .linear:
            if near(view(mask.start)) { return .start }
            if near(view(mask.end)) { return .end }
            return .newGradient
        default:
            return .paint
        }
    }
}

// MARK: - Filmstrip

struct Filmstrip: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(store.visiblePhotos) { photo in
                        ThumbnailView(photo: photo, maxSize: 150)
                            .frame(width: 96, height: 64)
                            .opacity(photo.flag == .reject ? 0.35 : 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(photo.url == store.currentID ? Theme.accent : .clear, lineWidth: 2)
                            )
                            .overlay(alignment: .bottomLeading) { StarsBadge(rating: photo.rating, size: 7) }
                            .contentShape(Rectangle())
                            .onTapGesture { store.select(photo) }
                            .id(photo.url)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .onChange(of: store.currentID) { _, id in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(store.currentID, anchor: .center) }
        }
        .background(Theme.panel)
    }
}
