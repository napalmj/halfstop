import SwiftUI

struct AdjustPanel: View {
    @Environment(LibraryStore.self) private var store
    @Environment(PreviewRenderer.self) private var renderer

    var body: some View {
        VStack(spacing: 0) {
            TabSwitch(selection: Binding(get: { store.panelTab }, set: { store.panelTab = $0 }))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            HistogramView(data: renderer.histogram)
                .frame(height: 74)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            if store.current == nil {
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if store.isCropping {
                            CropPanel()
                        } else if store.panelTab == .quick {
                            QuickPanel()
                        } else {
                            DetailedPanel()
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            PanelFooter()
        }
        .background(Theme.panel)
    }
}

private struct TabSwitch: View {
    @Binding var selection: PanelTab

    var body: some View {
        HStack(spacing: 2) {
            tab("Quick", .quick)
            tab("Detailed", .detailed)
        }
        .padding(2)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }

    private func tab(_ title: String, _ value: PanelTab) -> some View {
        Text(title)
            .font(.system(size: 12, weight: selection == value ? .semibold : .regular))
            .foregroundStyle(selection == value ? Theme.text : Theme.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(selection == value ? Theme.panelRaised : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { selection = value } }
    }
}

// MARK: - Slider helpers

private let signed: (Double) -> String = { v in
    let r = v.rounded()
    return r > 0 ? "+\(Int(r))" : "\(Int(r))"
}
private let ev: (Double) -> String = { v in String(format: v > 0 ? "+%.2f" : "%.2f", v) }
private let tempGradient = [Color(red: 0.3, green: 0.5, blue: 1), Color(white: 0.75), Color(red: 1, green: 0.8, blue: 0.3)]
private let tintGradient = [Color(red: 0.3, green: 0.85, blue: 0.35), Color(white: 0.75), Color(red: 0.95, green: 0.35, blue: 0.85)]

/// A slider bound to the current scope: the active mask's local value if it has one, else the global value.
private struct ScopedSlider: View {
    @Environment(LibraryStore.self) private var store
    let title: String
    let global: WritableKeyPath<Adjustments, Double>
    var local: WritableKeyPath<LocalAdjustments, Double>? = nil
    var range: ClosedRange<Double> = -100...100
    var step: Double = 1
    var format: (Double) -> String = signed
    var gradient: [Color]? = nil

    var body: some View {
        AdjustSlider(title: title,
                     value: store.scopedValue(global, local),
                     range: range, step: step, format: format, gradient: gradient,
                     onBegin: store.checkpoint,
                     onChange: { store.setScoped(global, local, $0) })
    }
}

// MARK: - Quick

private struct QuickPanel: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        let a = store.current?.adjustments ?? Adjustments()
        let modified = a.exposure != 0 || a.contrast != 0 || a.highlights != 0 || a.shadows != 0
            || a.temperature != 0 || a.saturation != 0 || a.vignette != 0
        PanelSection(title: "Basic", expanded: $expanded, isModified: modified, onReset: {
            store.resetSection { $0.exposure = 0; $0.contrast = 0; $0.highlights = 0; $0.shadows = 0
                $0.temperature = 0; $0.saturation = 0; $0.vignette = 0 }
        }) {
            ScopedSlider(title: "Exposure", global: \.exposure, range: -5...5, step: 0.05, format: ev)
            ScopedSlider(title: "Contrast", global: \.contrast)
            ScopedSlider(title: "Highlights", global: \.highlights)
            ScopedSlider(title: "Shadows", global: \.shadows)
            ScopedSlider(title: "Temperature", global: \.temperature, gradient: tempGradient)
            ScopedSlider(title: "Saturation", global: \.saturation)
            ScopedSlider(title: "Vignette", global: \.vignette)
        }
        CropButtonRow()
        HStack {
            Text("Need masks, curves or color wheels?")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button("Detailed") { store.panelTab = .detailed }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .padding(16)
    }
}

private struct CropButtonRow: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Button {
            store.isCropping = true
        } label: {
            HStack {
                Image(systemName: "crop")
                Text("Crop & straighten")
                Spacer()
                Text("C").foregroundStyle(Theme.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

// MARK: - Detailed

private struct DetailedPanel: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("sec.masks") private var masksOpen = true
    @AppStorage("sec.light") private var lightOpen = true
    @AppStorage("sec.color") private var colorOpen = true
    @AppStorage("sec.grading") private var gradingOpen = true
    @AppStorage("sec.curve") private var curveOpen = false
    @AppStorage("sec.hsl") private var hslOpen = false
    @AppStorage("sec.detail") private var detailOpen = false
    @AppStorage("sec.effects") private var effectsOpen = false

    var body: some View {
        let a = store.current?.adjustments ?? Adjustments()
        let mask = store.activeMask

        PanelSection(title: "Masks", expanded: $masksOpen) {
            MaskList()
        }

        if let mask {
            MaskSettings(mask: mask)
        }

        let lightModified: Bool = {
            if let mask { let l = mask.local; return l.exposure != 0 || l.contrast != 0 || l.highlights != 0 || l.shadows != 0 || l.whites != 0 || l.blacks != 0 }
            return a.exposure != 0 || a.contrast != 0 || a.highlights != 0 || a.shadows != 0 || a.whites != 0 || a.blacks != 0
        }()
        PanelSection(title: mask == nil ? "Light" : "Light · \(mask!.name)", expanded: $lightOpen, isModified: lightModified, onReset: {
            if mask != nil {
                store.checkpoint()
                store.editMask { $0.local.exposure = 0; $0.local.contrast = 0; $0.local.highlights = 0; $0.local.shadows = 0; $0.local.whites = 0; $0.local.blacks = 0 }
            } else {
                store.resetSection { $0.exposure = 0; $0.contrast = 0; $0.highlights = 0; $0.shadows = 0; $0.whites = 0; $0.blacks = 0 }
            }
        }) {
            ScopedSlider(title: "Exposure", global: \.exposure, local: \.exposure, range: -5...5, step: 0.05, format: ev)
            ScopedSlider(title: "Contrast", global: \.contrast, local: \.contrast)
            ScopedSlider(title: "Highlights", global: \.highlights, local: \.highlights)
            ScopedSlider(title: "Shadows", global: \.shadows, local: \.shadows)
            ScopedSlider(title: "Whites", global: \.whites, local: \.whites)
            ScopedSlider(title: "Blacks", global: \.blacks, local: \.blacks)
        }

        let colorModified: Bool = {
            if let mask { let l = mask.local; return l.temperature != 0 || l.tint != 0 || l.vibrance != 0 || l.saturation != 0 }
            return a.temperature != 0 || a.tint != 0 || a.vibrance != 0 || a.saturation != 0
        }()
        PanelSection(title: "Color", expanded: $colorOpen, isModified: colorModified, onReset: {
            if mask != nil {
                store.checkpoint()
                store.editMask { $0.local.temperature = 0; $0.local.tint = 0; $0.local.vibrance = 0; $0.local.saturation = 0 }
            } else {
                store.resetSection { $0.temperature = 0; $0.tint = 0; $0.vibrance = 0; $0.saturation = 0 }
            }
        }) {
            ScopedSlider(title: "Temperature", global: \.temperature, local: \.temperature, gradient: tempGradient)
            ScopedSlider(title: "Tint", global: \.tint, local: \.tint, gradient: tintGradient)
            ScopedSlider(title: "Vibrance", global: \.vibrance, local: \.vibrance)
            ScopedSlider(title: "Saturation", global: \.saturation, local: \.saturation)
        }

        if mask == nil {
            PanelSection(title: "Color grading", expanded: $gradingOpen, isModified: !a.grading.isNeutral || a.grading.balance != 0,
                         onReset: { store.resetSection { $0.grading = ColorGrading() } }) {
                GradingControls(grading: a.grading)
            }
            PanelSection(title: "Tone curve", expanded: $curveOpen, isModified: !a.curveIsIdentity,
                         onReset: { store.resetSection { $0.curve = Adjustments.identityCurve } }) {
                CurveSection(points: a.curve)
            }
            PanelSection(title: "HSL", expanded: $hslOpen, isModified: !a.hsl.allSatisfy(\.isNeutral),
                         onReset: { store.resetSection { $0.hsl = Adjustments().hsl } }) {
                HSLSection(bands: a.hsl)
            }
            PanelSection(title: "Detail", expanded: $detailOpen, isModified: a.sharpening != 0 || a.noiseReduction != 0,
                         onReset: { store.resetSection { $0.sharpening = 0; $0.noiseReduction = 0 } }) {
                ScopedSlider(title: "Sharpening", global: \.sharpening, range: 0...100, format: { "\(Int($0.rounded()))" })
                ScopedSlider(title: "Noise reduction", global: \.noiseReduction, range: 0...100, format: { "\(Int($0.rounded()))" })
            }
            PanelSection(title: "Effects", expanded: $effectsOpen, isModified: a.vignette != 0,
                         onReset: { store.resetSection { $0.vignette = 0 } }) {
                ScopedSlider(title: "Vignette", global: \.vignette)
            }
            CropButtonRow()
        }
    }
}

private struct MaskList: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let masks = store.current?.adjustments.masks ?? []
        VStack(spacing: 2) {
            row(icon: "photo", title: "Whole photo", selected: store.activeMaskID == nil) { store.activeMaskID = nil }
            ForEach(masks) { mask in
                HStack(spacing: 8) {
                    Image(systemName: mask.kind.symbol).frame(width: 16)
                    Text(mask.name)
                    if mask.kind.isAutomatic {
                        Text("auto").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                    if !mask.local.isNeutral {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    }
                    Spacer()
                    Button {
                        store.checkpoint()
                        store.editMask(mask.id) { $0.enabled.toggle() }
                    } label: {
                        Image(systemName: mask.enabled ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help(mask.enabled ? "Hide mask" : "Show mask")
                    Button { store.deleteMask(mask.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                        .help("Delete mask")
                }
                .font(.system(size: 12))
                .foregroundStyle(store.activeMaskID == mask.id ? Theme.text : Theme.secondary)
                .opacity(mask.enabled ? 1 : 0.5)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(store.activeMaskID == mask.id ? Theme.panelRaised : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture {
                    store.activeMaskID = mask.id
                    store.flashOverlay()
                }
            }
            Menu {
                ForEach(MaskKind.allCases) { kind in
                    Button { store.addMask(kind) } label: { Label(kind.label, systemImage: kind.symbol) }
                }
            } label: {
                Label("Add mask", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
    }

    private func row(icon: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16)
            Text(title)
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(selected ? Theme.text : Theme.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Theme.panelRaised : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

private struct MaskSettings: View {
    @Environment(LibraryStore.self) private var store
    @Environment(PreviewRenderer.self) private var renderer
    let mask: Mask
    @State private var open = true

    private let whole: (Double) -> String = { "\(Int($0.rounded()))" }

    var body: some View {
        PanelSection(title: "\(mask.kind.label) mask", expanded: $open) {
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if mask.kind == .subject {
                SubjectPicker(mask: mask, generation: renderer.generation)
            }
            ShapeList(mask: mask)
            if mask.kind.isAutomatic {
                AdjustSlider(title: "Grow / shrink", value: mask.grow, range: -100...100,
                             onBegin: store.checkpoint, onChange: { v in store.editMask { $0.grow = v } })
                AdjustSlider(title: "Softness", value: mask.softness, range: 0...100, format: whole,
                             onBegin: store.checkpoint, onChange: { v in store.editMask { $0.softness = v } })
            }
            if mask.kind == .brush {
                @Bindable var s = store
                brushSliders(flow: true)
                Toggle("Erase (or hold ⌥)", isOn: $s.brushErase)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            } else {
                refineControls
            }
            HStack {
                Toggle("Invert", isOn: Binding(get: { mask.invert }, set: { v in store.checkpoint(); store.editMask { $0.invert = v } }))
                    .toggleStyle(.checkbox)
                Spacer()
                Toggle("Overlay (O)", isOn: Binding(get: { store.showMaskOverlay }, set: { store.setOverlay($0) }))
                    .toggleStyle(.checkbox)
            }
            .font(.system(size: 11.5))
        }
    }

    @ViewBuilder
    private func brushSliders(flow: Bool) -> some View {
        AdjustSlider(title: "Brush size", value: store.brushSize * 1000, range: 5...250, format: whole,
                     onBegin: {}, onChange: { store.brushSize = $0 / 1000 })
        AdjustSlider(title: "Brush feather", value: store.brushFeather * 100, range: 0...100, format: whole,
                     onBegin: {}, onChange: { store.brushFeather = $0 / 100 })
        if flow {
            AdjustSlider(title: "Flow", value: store.brushFlow * 100, range: 5...100, format: whole,
                         onBegin: {}, onChange: { store.brushFlow = $0 / 100 })
        }
    }

    @ViewBuilder
    private var refineControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Refine with brush").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                Spacer()
                if !mask.strokes.isEmpty {
                    Button("Clear") {
                        store.checkpoint()
                        store.editMask { $0.strokes = [] }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .help("Remove all \(mask.strokes.count) refinement strokes")
                }
            }
            HStack(spacing: 4) {
                Button { store.refineMode = store.refineMode == .add ? nil : .add } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .buttonStyle(ChipStyle(selected: store.refineMode == .add))
                Button { store.refineMode = store.refineMode == .subtract ? nil : .subtract } label: {
                    Label("Subtract", systemImage: "minus.circle")
                }
                .buttonStyle(ChipStyle(selected: store.refineMode == .subtract))
            }
        }
        if store.refineMode != nil {
            brushSliders(flow: false)
            Text("Paint on the photo. Hold ⌥ to switch between add and subtract. Esc stops painting.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hint: String {
        switch mask.kind {
        case .radial: "Drag to move. Drag the edge dots to resize. ⇧-drag adds another."
        case .linear: "Drag across the photo to set the gradient. Drag the dots to adjust. ⇧-drag adds another gradient."
        case .brush: "Paint on the photo. Hold ⌥ to erase. [ and ] change size."
        case .subject: "People and objects detected automatically. Click one on the photo to include or exclude it."
        case .sky: "Bright, blue areas toward the top of the frame."
        }
    }
}

/// The mask's gradients: its own shape plus extras, each combined with a mode.
private struct ShapeList: View {
    @Environment(LibraryStore.self) private var store
    let mask: Mask

    var body: some View {
        let main = mask.mainShape
        VStack(alignment: .leading, spacing: 4) {
            if main != nil || !mask.shapes.isEmpty {
                Text("Shapes").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            if let main {
                row(main, title: "\(mask.name)", index: nil)
            }
            ForEach(Array(mask.shapes.enumerated()), id: \.element.id) { i, shape in
                row(shape, title: "\(shape.kind == .linear ? "Linear" : "Radial") \(i + (main == nil ? 1 : 2))", index: i)
            }
            Menu {
                Button { store.addShape(.linear) } label: { Label("Add linear gradient", systemImage: "rectangle.tophalf.filled") }
                Button { store.addShape(.radial) } label: { Label("Add radial gradient", systemImage: "circle.dashed") }
                Divider()
                Button { store.addShape(.linear, mode: .subtract) } label: { Label("Subtract linear gradient", systemImage: "minus.circle") }
                Button { store.addShape(.radial, mode: .subtract) } label: { Label("Subtract radial gradient", systemImage: "minus.circle") }
            } label: {
                Label("Add shape", systemImage: "plus").font(.system(size: 11.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Or ⇧-drag on the photo to add another gradient")
        }
        if let active = mask.shape(store.activeShapeID), active.kind == .radial {
            AdjustSlider(title: "Feather", value: active.feather * 100, range: 0...100, format: { "\(Int($0.rounded()))" },
                         onBegin: store.checkpoint,
                         onChange: { v in store.editMask { $0.editShape(store.activeShapeID) { $0.feather = v / 100 } } })
        }
    }

    private func row(_ shape: MaskShape, title: String, index: Int?) -> some View {
        let selected = index == nil ? (store.activeShapeID == nil || store.activeShapeID == mask.id) : store.activeShapeID == shape.id
        return HStack(spacing: 6) {
            Image(systemName: shape.kind == .linear ? "rectangle.tophalf.filled" : "circle.dashed").frame(width: 14)
            Text(title).lineLimit(1)
            Spacer()
            if index != nil {
                Menu {
                    ForEach(CombineMode.allCases) { mode in
                        Button { store.setShapeMode(shape.id, mode) } label: { Label(mode.label, systemImage: mode.symbol) }
                    }
                } label: {
                    Label(shape.mode.label, systemImage: shape.mode.symbol).font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { store.deleteShape(shape.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Delete shape")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(selected ? Theme.text : Theme.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Theme.panelRaised : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { store.activeShapeID = index == nil ? nil : shape.id }
    }
}

/// Chips for each detected subject.
private struct SubjectPicker: View {
    @Environment(LibraryStore.self) private var store
    let mask: Mask
    /// Re-read detection state when the renderer reports progress.
    let generation: Int

    var body: some View {
        if let url = store.currentID {
            if let count = SubjectDetector.shared.subjectCount(url) {
                if count == 0 {
                    Text("No subject found in this photo.").font(.system(size: 11.5)).foregroundStyle(.orange)
                } else {
                    let included = Set(mask.subjects ?? Array(1...count))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        Button("All") {
                            store.checkpoint()
                            store.editMask { $0.subjects = nil }
                        }
                        .buttonStyle(ChipStyle(selected: mask.subjects == nil))
                        ForEach(1...count, id: \.self) { n in
                            Button("\(n)") { store.setSubject(n, included: !included.contains(n), count: count) }
                                .buttonStyle(ChipStyle(selected: mask.subjects != nil && included.contains(n)))
                                .help(included.contains(n) ? "Exclude subject \(n)" : "Include subject \(n)")
                        }
                    }
                    Text("\(included.count) of \(count) subjects included")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finding subjects…").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

private struct GradingControls: View {
    @Environment(LibraryStore.self) private var store
    let grading: ColorGrading

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                wheel("Shadows", \.shadows)
                Spacer()
                wheel("Midtones", \.midtones)
                Spacer()
                wheel("Highlights", \.highlights)
            }
            lum("Shadow luminance", \.shadows)
            lum("Midtone luminance", \.midtones)
            lum("Highlight luminance", \.highlights)
            AdjustSlider(title: "Balance", value: grading.balance, range: -100...100,
                         onBegin: store.checkpoint, onChange: { v in store.edit { $0.grading.balance = v } })
        }
    }

    private func wheel(_ title: String, _ kp: WritableKeyPath<ColorGrading, GradeWheel>) -> some View {
        ColorWheel(title: title, wheel: grading[keyPath: kp], diameter: 72, onBegin: store.checkpoint,
                   onChange: { w in store.edit { $0.grading[keyPath: kp] = w } })
    }

    private func lum(_ title: String, _ kp: WritableKeyPath<ColorGrading, GradeWheel>) -> some View {
        AdjustSlider(title: title, value: grading[keyPath: kp].luminance, range: -100...100,
                     onBegin: store.checkpoint, onChange: { v in store.edit { $0.grading[keyPath: kp].luminance = v } })
    }
}

private struct CurveSection: View {
    @Environment(LibraryStore.self) private var store
    @Environment(PreviewRenderer.self) private var renderer
    let points: [CurvePoint]

    var body: some View {
        CurveEditor(points: points, histogram: renderer.histogram, onBegin: store.checkpoint,
                    onChange: { pts in store.edit { $0.curve = pts } })
        Text("Drag to add or move points. Drag a point off the graph to remove it.")
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.secondary)
    }
}

private struct HSLSection: View {
    @Environment(LibraryStore.self) private var store
    let bands: [HSLBand]
    @AppStorage("hsl.mode") private var mode = 0

    var body: some View {
        Picker("", selection: $mode) {
            Text("Hue").tag(0)
            Text("Saturation").tag(1)
            Text("Luminance").tag(2)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        ForEach(HSLColor.allCases) { color in
            let band = bands[color.rawValue]
            let h = color.centerHue / 360
            let value = mode == 0 ? band.hue : mode == 1 ? band.saturation : band.luminance
            let gradient: [Color] = switch mode {
            case 0: [Color(hue: (color.centerHue - 30 + 360).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.75, brightness: 0.9),
                     Color(hue: h, saturation: 0.75, brightness: 0.9),
                     Color(hue: (color.centerHue + 30).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.75, brightness: 0.9)]
            case 1: [Color(hue: h, saturation: 0, brightness: 0.7), Color(hue: h, saturation: 0.9, brightness: 0.9)]
            default: [Color(hue: h, saturation: 0.8, brightness: 0.25), Color(hue: h, saturation: 0.5, brightness: 1)]
            }
            AdjustSlider(title: color.name, value: value, range: -100...100, gradient: gradient,
                         onBegin: store.checkpoint,
                         onChange: { v in
                             store.edit { a in
                                 switch mode {
                                 case 0: a.hsl[color.rawValue].hue = v
                                 case 1: a.hsl[color.rawValue].saturation = v
                                 default: a.hsl[color.rawValue].luminance = v
                                 }
                             }
                         })
        }
    }
}

// MARK: - Crop

private struct CropPanel: View {
    @Environment(LibraryStore.self) private var store
    @Environment(PreviewRenderer.self) private var renderer
    @State private var open = true

    var body: some View {
        let a = store.current?.adjustments ?? Adjustments()
        PanelSection(title: "Crop & straighten", expanded: $open, isModified: !a.crop.isIdentity,
                     onReset: { store.resetSection { $0.crop = CropSettings() } }) {
            Text("Aspect").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(AspectRatio.allCases) { ratio in
                    Button(ratio.label) { setAspect(ratio, portrait: a.crop.portrait) }
                        .buttonStyle(ChipStyle(selected: a.crop.aspect == ratio))
                }
            }
            if a.crop.aspect != .free && a.crop.aspect != .square {
                Button {
                    setAspect(a.crop.aspect, portrait: !a.crop.portrait)
                } label: {
                    Label(a.crop.portrait ? "Portrait" : "Landscape", systemImage: "rotate.right")
                }
                .buttonStyle(ChipStyle(selected: false))
            }
            AdjustSlider(title: "Straighten", value: a.crop.angle, range: -45...45, step: 0.1,
                         format: { String(format: "%.1f°", $0) },
                         onBegin: store.checkpoint, onChange: { v in store.edit { $0.crop.angle = v } })
            HStack {
                Spacer()
                Button("Done") { store.isCropping = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func setAspect(_ ratio: AspectRatio, portrait: Bool) {
        guard let url = store.currentID, let source = renderer.source(for: url) else { return }
        store.checkpoint()
        store.edit { a in
            a.crop.aspect = ratio
            a.crop.portrait = portrait
            let frame = ImageSource.straightenedFrameSize(size: source.size, angle: a.crop.angle)
            a.crop.rect = CropOverlay.fitted(ratio: a.crop.pixelRatio(imageSize: source.size), around: a.crop.rect, frameSize: frame)
        }
    }
}

struct ChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .foregroundStyle(selected ? Color.black : Theme.text)
            .background(selected ? Theme.accent : Theme.panelRaised.opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Footer

private struct PanelFooter: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                if store.presets.isEmpty {
                    Text("No presets yet")
                }
                ForEach(store.presets) { preset in
                    Button(preset.name) { store.apply(preset) }
                }
                Divider()
                Button("Save current as preset…") { store.showSavePreset = true }
                if !store.presets.isEmpty {
                    Menu("Delete preset") {
                        ForEach(store.presets) { preset in
                            Button(preset.name, role: .destructive) { store.deletePreset(preset) }
                        }
                    }
                }
            } label: {
                Text("Presets")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            footerButton("doc.on.doc", "Copy settings (⇧⌘C)") { store.copySettings() }
            footerButton("doc.on.clipboard", "Paste settings (⇧⌘V)") { store.pasteSettings() }
                .disabled(store.clipboard == nil)
            footerButton("arrow.counterclockwise", "Reset all (⇧⌘R)") { store.resetAdjustments() }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func footerButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text.opacity(0.8))
        .help(help)
    }
}
