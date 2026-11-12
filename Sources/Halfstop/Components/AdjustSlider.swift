import SwiftUI
import AppKit

enum Theme {
    static let background = Color(red: 0.09, green: 0.09, blue: 0.095)
    static let panel = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let panelRaised = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let hairline = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.88)
    static let secondary = Color.white.opacity(0.5)
    static let accent = Color(red: 0.98, green: 0.72, blue: 0.32)
    static let track = Color.white.opacity(0.12)
}

/// The slider under the pointer, so ↑/↓ can nudge it (see `KeyHandler`).
@MainActor
final class SliderFocus {
    static let shared = SliderFocus()
    private(set) var id: UUID?
    private var nudger: ((Double) -> Void)?

    func set(_ id: UUID, nudge: @escaping (Double) -> Void) { self.id = id; nudger = nudge }
    func clear(_ id: UUID) { if self.id == id { self.id = nil; nudger = nil } }

    /// Moves the hovered slider by `steps` small steps. False when no slider is hovered.
    func nudge(_ steps: Double) -> Bool {
        guard let nudger else { return false }
        nudger(steps)
        return true
    }
}

/// A compact slider tuned for photo editing:
/// - drag anywhere on the track; hold ⌥ for fine control
/// - gentle detent at the default value
/// - double-click the label to reset; click the value to type one
/// - hover and press ↑/↓ to nudge (⇧ for bigger steps)
struct AdjustSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var step: Double = 1
    var format: (Double) -> String = { v in
        let r = v.rounded()
        return r > 0 ? "+\(Int(r))" : "\(Int(r))"
    }
    var gradient: [Color]? = nil
    let onBegin: () -> Void
    let onChange: (Double) -> Void

    @State private var dragging = false
    @State private var dragStart: (value: Double, x: CGFloat)? = nil
    @State private var hovering = false
    @State private var editing = false
    @State private var typed = ""
    @State private var lastNudge = Date.distantPast
    @State private var focusID = UUID()
    @FocusState private var fieldFocused: Bool

    private var span: Double { range.upperBound - range.lowerBound }

    private func fraction(_ v: Double) -> CGFloat {
        CGFloat((v - range.lowerBound) / span)
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .foregroundStyle(value == defaultValue ? Theme.secondary : Theme.text)
                Spacer()
                if editing {
                    TextField("", text: $typed)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 56)
                        .padding(.horizontal, 3)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                        .focused($fieldFocused)
                        .onSubmit(commitTyped)
                        .onExitCommand { editing = false }
                        .onChange(of: fieldFocused) { _, focused in if !focused { commitTyped() } }
                } else {
                    Text(format(value))
                        .monospacedDigit()
                        .foregroundStyle(value == defaultValue ? Theme.secondary : Theme.text)
                        .contentShape(Rectangle())
                        .onTapGesture { startTyping() }
                        .help("Click to type a value")
                }
            }
            .font(.system(size: 11.5))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { reset() }
            .help("Double-click to reset")

            GeometryReader { geo in
                let w = geo.size.width
                let x = fraction(value) * w
                let zeroX = fraction(min(max(defaultValue, range.lowerBound), range.upperBound)) * w
                ZStack(alignment: .leading) {
                    if let gradient {
                        Capsule()
                            .fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                            .frame(height: 3)
                            .opacity(0.75)
                    } else {
                        Capsule().fill(Theme.track).frame(height: 3)
                        Rectangle()
                            .fill(Theme.text.opacity(0.55))
                            .frame(width: abs(x - zeroX), height: 3)
                            .offset(x: min(x, zeroX))
                    }
                    Circle()
                        .fill(dragging ? Theme.accent : Color.white.opacity(hovering ? 1 : 0.9))
                        .frame(width: dragging ? 13 : 11, height: dragging ? 13 : 11)
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
                        .offset(x: x - (dragging ? 6.5 : 5.5))
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let fine = NSEvent.modifierFlags.contains(.option)
                            if !dragging {
                                dragging = true
                                onBegin()
                                dragStart = (value, g.startLocation.x)
                                if !fine { update(fromX: g.location.x, width: w) }
                                return
                            }
                            if fine, let start = dragStart {
                                let delta = Double((g.location.x - start.x) / w) * span * 0.1
                                commit(start.value + delta)
                            } else {
                                dragStart = (value, g.location.x)
                                update(fromX: g.location.x, width: w)
                            }
                        }
                        .onEnded { _ in
                            dragging = false
                            dragStart = nil
                        }
                )
                .onHover { hovering = $0 }
            }
            .frame(height: 16)
        }
        .animation(.easeOut(duration: 0.1), value: dragging)
        .onHover { inside in
            if inside { registerNudge() } else { SliderFocus.shared.clear(focusID) }
        }
        // Re-register so a nudge starts from the current value (after a drag, undo…).
        .onChange(of: value) { if SliderFocus.shared.id == focusID { registerNudge() } }
        .onDisappear { SliderFocus.shared.clear(focusID) }
    }

    /// One nudge step: 1/200 of the range (1 on a ±100 slider, 0.05 EV on exposure), at least `step`.
    private var nudgeUnit: Double { max(step, span / 200) }

    private func registerNudge() {
        let start = value
        SliderFocus.shared.set(focusID) { steps in
            // A burst of key presses is one history step.
            if Date().timeIntervalSince(lastNudge) > LibraryStore.historySettle { onBegin() }
            lastNudge = Date()
            commit(start + steps * nudgeUnit)
        }
    }

    private func startTyping() {
        typed = format(value).replacingOccurrences(of: "+", with: "")
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitTyped() {
        guard editing else { return }
        editing = false
        let cleaned = typed.replacingOccurrences(of: ",", with: ".").filter { "-0123456789.".contains($0) }
        guard let v = Double(cleaned) else { return }
        onBegin()
        commit(v)
    }

    private func update(fromX x: CGFloat, width: CGFloat) {
        var v = range.lowerBound + Double(min(max(x / width, 0), 1)) * span
        // Detent: snap to the default when close.
        if abs(v - defaultValue) < span * 0.012 { v = defaultValue }
        commit(v)
    }

    private func commit(_ raw: Double) {
        var v = min(max(raw, range.lowerBound), range.upperBound)
        v = (v / step).rounded() * step
        if v != value { onChange(v) }
    }

    private func reset() {
        guard value != defaultValue else { return }
        onBegin()
        onChange(defaultValue)
    }
}

/// Collapsible panel section with an optional per-section reset.
struct PanelSection<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    var isModified = false
    var onReset: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(Theme.secondary)
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.text.opacity(0.8))
                if isModified {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                }
                Spacer()
                if isModified, let onReset {
                    Button("Reset", action: onReset)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }

            if expanded {
                VStack(alignment: .leading, spacing: 12) { content() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}
