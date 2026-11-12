import SwiftUI

struct EditorView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            if store.showHistory {
                HistoryPanel()
                Rectangle().fill(Theme.hairline).frame(width: 1)
            }
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
    let revision: Int
    let before: Bool
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
        // Show the red overlay when asked, while a mask is being drawn, or when the mask has no
        // adjustments yet (otherwise fresh brush strokes would be invisible).
        let wantsOverlay = store.showMaskOverlay || store.maskInteracting || (store.activeMask?.local.isNeutral ?? false)
        let overlayID = wantsOverlay && !store.showBefore ? store.activeMaskID : nil
        let token = PreviewToken(url: url, revision: photo.revision, before: store.showBefore, geometry: "\(mode)", overlay: overlayID, generation: renderer.generation)

        PreviewImageView(
            token: token,
            provider: { drawable, scale in
                renderer.source(for: url).map {
                    PreviewRenderer.previewImage($0, shown, geometry: mode, overlayMask: overlayID, drawableSize: drawable, scale: scale)
                }
            },
            onHistogram: overlayID == nil ? { renderer.receiveHistogram($0) } : nil
        )

        if let source = renderer.source(for: url) {
            let contentSize = PreviewLayout.contentSize(source.size, a, mode)
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

    private enum Drag: Equatable {
        case center(UUID), radiusX(UUID), radiusY(UUID), start(UUID), end(UUID)
        case redefine(UUID), newShape(UUID), paint, pickSubject
    }

    /// Brush masks always paint; other masks paint while Add/Subtract is on.
    private var painting: Bool { mask.kind == .brush || store.refineMode != nil }
    @State private var drag: Drag?
    @State private var dragStart: CGPoint?
    @State private var hover: CGPoint?
    /// Resets even when SwiftUI cancels a gesture without calling onEnded.
    @GestureState private var gestureActive = false

    private var allShapes: [MaskShape] { (mask.mainShape.map { [$0] } ?? []) + mask.shapes }
    /// The shape the handles edit: the selected extra shape, else the mask's own.
    private var activeShape: MaskShape? { mask.shape(store.activeShapeID) }

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
            if mask.kind == .sky && mask.shapes.isEmpty && !painting && !NSEvent.modifierFlags.contains(.shift) {
                Color.clear
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($gestureActive) { _, state, _ in state = true }
                        .onChanged(changed)
                        .onEnded { _ in endDrag() })
                    .onChange(of: gestureActive) { _, active in
                        if !active { endDrag() }
                    }
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { hover = p } else { hover = nil }
                    }
            }
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext) {
        let activeID = activeShape?.id
        // Inactive shapes first, faint and without handles; the active one on top.
        for shape in allShapes where shape.id != activeID { drawShape(&ctx, shape, active: false) }
        if let active = activeShape { drawShape(&ctx, active, active: !painting) }
        if painting, let hover {
            let white = Color.white.opacity(0.9)
            let r = store.brushSize * longEdge
            ctx.stroke(Path(ellipseIn: CGRect(x: hover.x - r, y: hover.y - r, width: r * 2, height: r * 2)), with: .color(white), lineWidth: 1)
            let ri = r * (1 - store.brushFeather)
            if ri > 1 {
                ctx.stroke(Path(ellipseIn: CGRect(x: hover.x - ri, y: hover.y - ri, width: ri * 2, height: ri * 2)),
                           with: .color(white.opacity(0.4)), lineWidth: 1)
            }
        }
    }

    private func drawShape(_ ctx: inout GraphicsContext, _ shape: MaskShape, active: Bool) {
        let alpha = active ? 0.9 : 0.35
        let white = Color.white.opacity(alpha)
        switch shape.kind {
        case .radial:
            let c = view(shape.center)
            let rx = shape.radiusX * imageRect.width, ry = shape.radiusY * imageRect.height
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2)), with: .color(white), lineWidth: 1.2)
            let k = 1 - shape.feather
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rx * k, y: c.y - ry * k, width: rx * k * 2, height: ry * k * 2)),
                       with: .color(white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            if active {
                dot(&ctx, c, 5)
                dot(&ctx, CGPoint(x: c.x + rx, y: c.y), 4)
                dot(&ctx, CGPoint(x: c.x, y: c.y - ry), 4)
            }
        case .linear:
            let s = view(shape.start), e = view(shape.end)
            let dx = e.x - s.x, dy = e.y - s.y
            let len = max(hypot(dx, dy), 1)
            let px = -dy / len * 4000, py = dx / len * 4000
            for (p, solid) in [(s, true), (e, false), (CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2), false)] {
                var path = Path()
                path.move(to: CGPoint(x: p.x - px, y: p.y - py))
                path.addLine(to: CGPoint(x: p.x + px, y: p.y + py))
                ctx.stroke(path, with: .color(white.opacity(solid ? 1 : 0.55)), style: StrokeStyle(lineWidth: 1, dash: solid ? [] : [5, 4]))
            }
            if active {
                dot(&ctx, s, 5)
                dot(&ctx, e, 4)
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - 3, y: s.y - 3, width: 6, height: 6)), with: .color(white))
            }
        }
    }

    private func dot(_ ctx: inout GraphicsContext, _ p: CGPoint, _ r: CGFloat) {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(.white))
        ctx.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.4)), lineWidth: 1)
    }

    // MARK: Interaction

    private func edit(_ shapeID: UUID, _ change: @escaping (inout MaskShape) -> Void) {
        store.editMask(mask.id) { $0.editShape(shapeID, change) }
    }

    private func changed(_ g: DragGesture.Value) {
        hover = g.location
        // A new start location means a new gesture, even if the last one never reported its end.
        if drag == nil || dragStart != g.startLocation {
            dragStart = g.startLocation
            store.maskInteracting = true
            let picked = pick(g.startLocation, shift: NSEvent.modifierFlags.contains(.shift))
            if case .newShape = picked {
                // addShape records its own undo step.
            } else {
                store.checkpoint()
            }
            drag = picked
            if drag == .paint {
                let option = NSEvent.modifierFlags.contains(.option)
                let erase = mask.kind == .brush ? (store.brushErase || option) : ((store.refineMode == .subtract) != option)
                let stroke = BrushStroke(points: [norm(g.startLocation)], radius: store.brushSize, feather: store.brushFeather,
                                         flow: store.brushFlow, erase: erase)
                store.editMask(mask.id) { $0.strokes.append(stroke) }
                return
            }
        }
        let p = norm(g.location)
        let s = norm(g.startLocation)
        let moved = hypot(g.translation.width, g.translation.height) > 4
        switch drag {
        case .center(let id): edit(id) { $0.center = p }
        case .radiusX(let id): edit(id) { $0.radiusX = max(0.01, abs(p.x - $0.center.x)) }
        case .radiusY(let id): edit(id) { $0.radiusY = max(0.01, abs(p.y - $0.center.y)) }
        case .start(let id): edit(id) { $0.start = p }
        case .end(let id): edit(id) { $0.end = p }
        case .redefine(let id), .newShape(let id):
            guard moved else { break }
            edit(id) { shape in
                if shape.kind == .linear {
                    shape.start = s; shape.end = p
                } else {
                    shape.center = s
                    shape.radiusX = max(0.01, abs(p.x - s.x)); shape.radiusY = max(0.01, abs(p.y - s.y))
                }
            }
        case .pickSubject, nil:
            break
        case .paint:
            store.editMask(mask.id) { m in
                guard !m.strokes.isEmpty else { return }
                m.strokes[m.strokes.count - 1].points.append(p)
            }
        }
    }

    private func endDrag() {
        if drag == .pickSubject, let start = dragStart, let hover, hypot(hover.x - start.x, hover.y - start.y) < 5 {
            store.toggleSubject(at: norm(start))
        }
        drag = nil
        dragStart = nil
        store.maskInteracting = false
    }

    private func pick(_ loc: CGPoint, shift: Bool) -> Drag? {
        if painting { return .paint }
        let near: (CGPoint) -> Bool = { hypot($0.x - loc.x, $0.y - loc.y) < 14 }

        // ⇧-drag: start a new shape (same kind as the one being edited, else linear).
        if shift {
            let kind = activeShape?.kind ?? .linear
            let start = norm(loc)
            if let id = store.addShape(kind, configure: { shape in
                shape.start = start; shape.end = start
                shape.center = start; shape.radiusX = 0.01; shape.radiusY = 0.01
            }) {
                return .newShape(id)
            }
        }

        // Handles: the active shape first, then any other shape (which also selects it).
        let ordered = (activeShape.map { [$0] } ?? []) + allShapes.filter { $0.id != activeShape?.id }
        for shape in ordered {
            var hit: Drag?
            switch shape.kind {
            case .radial:
                let c = view(shape.center)
                if near(CGPoint(x: c.x + shape.radiusX * imageRect.width, y: c.y)) { hit = .radiusX(shape.id) }
                else if near(CGPoint(x: c.x, y: c.y - shape.radiusY * imageRect.height)) { hit = .radiusY(shape.id) }
                else if near(c) { hit = .center(shape.id) }
            case .linear:
                if near(view(shape.start)) { hit = .start(shape.id) }
                else if near(view(shape.end)) { hit = .end(shape.id) }
            }
            if let hit {
                store.activeShapeID = shape.id == mask.id ? nil : shape.id
                return hit
            }
        }

        if mask.kind == .subject && store.activeShapeID == nil { return .pickSubject }
        guard let active = activeShape else { return nil }
        // Empty space: a linear is redrawn from here; a radial moves here.
        return active.kind == .linear ? .redefine(active.id) : .center(active.id)
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
                        FilmstripCell(photo: photo, isCurrent: photo.url == store.currentID)
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

/// Its own view so a cell's edits re-render only that cell, not the whole strip.
private struct FilmstripCell: View {
    @Environment(LibraryStore.self) private var store
    let photo: Photo
    let isCurrent: Bool

    var body: some View {
        ThumbnailView(photo: photo, maxSize: 150)
            .frame(width: 96, height: 64)
            .opacity(photo.flag == .reject ? 0.35 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Theme.accent : .clear, lineWidth: 2)
            )
            .overlay(alignment: .bottomLeading) { StarsBadge(rating: photo.rating, size: 7) }
            .overlay(alignment: .topTrailing) {
                if !photo.adjustments.isDefault { EditedBadge(compact: true).padding(3) }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.select(photo) }
    }
}
