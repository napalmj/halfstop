import SwiftUI
import AppKit

extension View {
    /// A hover tooltip naming an action and its key, drawn as “Pick  [P]”.
    ///
    /// Use it instead of `.help` in the top bar: the top bar sits in the window's hidden title bar,
    /// where system tooltips never appear. The tip is drawn in a small window of its own, so it
    /// works there and isn't clipped by the views around it. Leave `key` out for a plain tip.
    func shortcutTip(_ text: String, key: String? = nil) -> some View {
        modifier(ShortcutTipModifier(text: text, key: key))
    }
}

private struct ShortcutTipModifier: ViewModifier {
    let text: String
    let key: String?
    @State private var anchor = TipAnchor()

    func body(content: Content) -> some View {
        content
            .background(TipAnchorView(anchor: anchor))
            .onHover { inside in
                if inside {
                    ShortcutTips.shared.enter(anchor, text: text, key: key)
                } else {
                    ShortcutTips.shared.leave(anchor)
                }
            }
            .onChange(of: text) { ShortcutTips.shared.update(anchor, text: text, key: key) }
            .onChange(of: key) { ShortcutTips.shared.update(anchor, text: text, key: key) }
            .accessibilityHint(key.map { "\(text) (\($0))" } ?? text)
    }
}

/// Holds the AppKit view behind a tipped view, so the tip can be placed next to it on screen.
private final class TipAnchor {
    weak var view: NSView?
}

private struct TipAnchorView: NSViewRepresentable {
    let anchor: TipAnchor

    func makeNSView(context: Context) -> TipAnchorNSView {
        let view = TipAnchorNSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: TipAnchorNSView, context: Context) {
        anchor.view = view
    }
}

private final class TipAnchorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The tipped view went away while hovered (the mode changed, say): take its tip with it.
        if window == nil { ShortcutTips.shared.anchorRemoved(self) }
    }
}

/// Shows one tip at a time, after a short hover. Moving straight on to another tipped control
/// shows its tip at once, like system tooltips. A click, key press or scroll hides it.
@MainActor
final class ShortcutTips {
    static let shared = ShortcutTips()

    private static let delay: Duration = .milliseconds(600)
    /// Within this long of a tip closing, the next one opens without the delay.
    private static let warmWindow: TimeInterval = 0.4

    private var panel: NSPanel?
    private weak var owner: NSView?
    private var pending: Task<Void, Never>?
    private var lastHidden = Date.distantPast
    private var monitor: Any?

    fileprivate func enter(_ anchor: TipAnchor, text: String, key: String?) {
        guard let view = anchor.view else { return }
        pending?.cancel()
        pending = nil
        owner = view
        if panel?.isVisible == true || Date().timeIntervalSince(lastHidden) < Self.warmWindow {
            show(text, key: key, at: view)
            return
        }
        pending = Task { [weak self, weak view] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self, let view, self.owner === view else { return }
            self.show(text, key: key, at: view)
        }
    }

    fileprivate func leave(_ anchor: TipAnchor) {
        guard let view = anchor.view, owner === view else { return }
        hide()
    }

    fileprivate func update(_ anchor: TipAnchor, text: String, key: String?) {
        guard let view = anchor.view, owner === view, panel?.isVisible == true else { return }
        show(text, key: key, at: view)
    }

    fileprivate func anchorRemoved(_ view: NSView) {
        if owner === view { hide() }
    }

    func hide() {
        pending?.cancel()
        pending = nil
        owner = nil
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        lastHidden = Date()
    }

    private func show(_ text: String, key: String?, at view: NSView) {
        guard NSApp.isActive, let window = view.window, window.isVisible, window.attachedSheet == nil else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let host = NSHostingController(rootView: TipBubble(text: text, key: key))
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 1000))
        host.view.frame = CGRect(origin: .zero, size: size)
        panel.contentViewController = host

        // Centred under the control, kept on screen; above it if there's no room below.
        let anchorRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        var origin = CGPoint(x: anchorRect.midX - size.width / 2, y: anchorRect.minY - 6 - size.height)
        if origin.y < screen.minY { origin.y = anchorRect.maxY + 6 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { event in
            MainActor.assumeIsolated { ShortcutTips.shared.hide() }
            return event
        }
        return panel
    }
}

private struct TipBubble: View {
    let text: String
    let key: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let key {
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                    .fixedSize()
            }
        }
        .font(.system(size: 11.5))
        .padding(.leading, 9)
        .padding(.trailing, key == nil ? 9 : 5)
        .padding(.vertical, key == nil ? 5 : 4)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}
