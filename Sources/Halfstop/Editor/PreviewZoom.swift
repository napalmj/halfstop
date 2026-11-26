import SwiftUI
import AppKit

/// How far the editor is zoomed into the photo, and where.
///
/// `scale` is relative to fitting the photo in the view (1 = fit). `focus` is the point of the
/// photo (0…1 across and down) at the middle of the view. Both are independent of the photo's
/// size, so the zoom carries over when you move to the next photo: handy for checking focus
/// across a burst.
struct PreviewZoom: Equatable {
    var scale: CGFloat = 1
    var focus = CGPoint(x: 0.5, y: 0.5)

    var isZoomed: Bool { scale > 1.001 }

    /// Where the photo sits in a view of `bounds` (top-left origin, points). Zoomed in, it's kept
    /// covering the view: you can't pan past its edges.
    func rect(content: CGSize, in bounds: CGSize) -> CGRect {
        let fit = PreviewLayout.fit(content, in: bounds)
        guard isZoomed, fit.width > 0 else { return fit }
        let size = CGSize(width: fit.width * scale, height: fit.height * scale)
        func place(_ length: CGFloat, _ view: CGFloat, _ focus: CGFloat) -> CGFloat {
            guard length > view else { return (view - length) / 2 }
            return min(0, max(view - length, view / 2 - focus * length))
        }
        return CGRect(x: place(size.width, bounds.width, focus.x), y: place(size.height, bounds.height, focus.y),
                      width: size.width, height: size.height)
    }

    /// Zooms by `factor`, keeping the photo point under `anchor` (a view point) where it is.
    mutating func zoom(by factor: CGFloat, anchor: CGPoint, content: CGSize, in bounds: CGSize, maxScale: CGFloat) {
        let before = rect(content: content, in: bounds)
        guard before.width > 0, before.height > 0 else { return }
        let point = CGPoint(x: (anchor.x - before.minX) / before.width, y: (anchor.y - before.minY) / before.height)
        let newScale = min(max(scale * factor, 1), max(maxScale, 1))
        let fit = PreviewLayout.fit(content, in: bounds)
        let size = CGSize(width: fit.width * newScale, height: fit.height * newScale)
        scale = newScale
        // The new rect puts `point` under `anchor`; focus is the photo point at the view's middle.
        let origin = CGPoint(x: anchor.x - point.x * size.width, y: anchor.y - point.y * size.height)
        focus = CGPoint(x: (bounds.width / 2 - origin.x) / size.width, y: (bounds.height / 2 - origin.y) / size.height)
        settle(content: content, in: bounds)
    }

    /// Moves the photo by `delta` view points (it follows the fingers or the pointer).
    mutating func pan(by delta: CGSize, content: CGSize, in bounds: CGSize) {
        guard isZoomed else { return }
        let r = rect(content: content, in: bounds)
        guard r.width > 0, r.height > 0 else { return }
        focus = CGPoint(x: (bounds.width / 2 - (r.minX + delta.width)) / r.width,
                        y: (bounds.height / 2 - (r.minY + delta.height)) / r.height)
        settle(content: content, in: bounds)
    }

    /// Fit, or the given scale centred on `anchor` (100% from a double-click or Z).
    mutating func toggle(to target: CGFloat, anchor: CGPoint?, content: CGSize, in bounds: CGSize) {
        if isZoomed {
            scale = 1
            focus = CGPoint(x: 0.5, y: 0.5)
            return
        }
        // The point clicked moves to the middle of the view (as far as the photo's edges allow).
        let fit = PreviewLayout.fit(content, in: bounds)
        if let anchor, fit.width > 0, fit.height > 0 {
            focus = CGPoint(x: min(max((anchor.x - fit.minX) / fit.width, 0), 1),
                            y: min(max((anchor.y - fit.minY) / fit.height, 0), 1))
        } else {
            focus = CGPoint(x: 0.5, y: 0.5)
        }
        scale = max(target, 1.01)
        settle(content: content, in: bounds)
    }

    /// Pulls `focus` back to what the view can actually show (after the photo was kept covering it).
    private mutating func settle(content: CGSize, in bounds: CGSize) {
        guard isZoomed else {
            scale = 1
            focus = CGPoint(x: 0.5, y: 0.5)
            return
        }
        let r = rect(content: content, in: bounds)
        guard r.width > 0, r.height > 0 else { return }
        focus = CGPoint(x: (bounds.width / 2 - r.minX) / r.width, y: (bounds.height / 2 - r.minY) / r.height)
    }
}

/// The geometry the zoom gestures need, kept current by `PreviewArea` as it lays out. Not observed:
/// only the event handlers read it.
@MainActor
final class PreviewZoomContext {
    var bounds: CGSize = .zero
    var content: CGSize = .zero
    /// The pointer, while it's over the preview (view points).
    var hover: CGPoint?
    /// The zoom that shows the photo at 100% (one photo pixel per screen pixel).
    var actualSize: CGFloat = 2
    /// Zooming in stops at 400%.
    var maxScale: CGFloat { max(actualSize * 4, 2) }
}

/// Pinch, scroll and two-finger double-tap over the preview:
/// - a pinch on the trackpad zooms around the pointer;
/// - a mouse's scroll wheel zooms around the pointer (so does a trackpad with ⌘ or ⌥ held);
/// - two-finger scrolling on the trackpad pans while zoomed in;
/// - a two-finger double-tap (smart zoom) toggles between fit and 100%.
@MainActor
final class PreviewZoomEvents {
    private var monitor: Any?

    func install(store: LibraryStore, context: PreviewZoomContext) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel, .smartMagnify]) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { Self.handle(event, store: store, context: context) }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func handle(_ event: NSEvent, store: LibraryStore, context: PreviewZoomContext) -> Bool {
        guard store.mode == .edit, !store.isCropping, let anchor = context.hover,
              event.window === NSApp.keyWindow, NSApp.keyWindow?.attachedSheet == nil,
              context.bounds.width > 0, context.content.width > 0 else { return false }
        let content = context.content, bounds = context.bounds
        switch event.type {
        case .magnify:
            store.zoom.zoom(by: 1 + event.magnification, anchor: anchor, content: content, in: bounds, maxScale: context.maxScale)
            return true
        case .smartMagnify:
            store.zoom.toggle(to: context.actualSize, anchor: anchor, content: content, in: bounds)
            return true
        case .scrollWheel:
            let trackpad = event.hasPreciseScrollingDeltas
            let zoomKey = !event.modifierFlags.intersection([.command, .option]).isEmpty
            if trackpad && !zoomKey {
                guard store.zoom.isZoomed else { return false }
                store.zoom.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), content: content, in: bounds)
                return true
            }
            // The wheel's physical direction: rolled away from you (or fingers up) zooms in,
            // whatever the natural-scrolling setting.
            let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            guard dy != 0 else { return true }
            let factor = trackpad ? exp(dy * 0.01) : pow(1.2, dy)
            store.zoom.zoom(by: factor, anchor: anchor, content: content, in: bounds, maxScale: context.maxScale)
            return true
        default:
            return false
        }
    }
}

/// Over the photo while zoomed in: drag to pan (an open hand), double-click to go back to fit.
/// When nothing is zoomed, a double-click zooms to 100% on the point clicked. Sits under the
/// editing tools; hold Space to pan with a tool active.
struct ZoomPanLayer: View {
    @Environment(LibraryStore.self) private var store
    let context: PreviewZoomContext
    @State private var last: CGSize?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard store.zoom.isZoomed || store.spacePanning else { return }
                if case .active = phase { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        guard store.zoom.isZoomed else { return }
                        NSCursor.closedHand.set()
                        let previous = last ?? .zero
                        let delta = CGSize(width: g.translation.width - previous.width, height: g.translation.height - previous.height)
                        last = g.translation
                        store.zoom.pan(by: delta, content: context.content, in: context.bounds)
                    }
                    .onEnded { _ in
                        last = nil
                        if store.zoom.isZoomed { NSCursor.openHand.set() }
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { tap in
                    store.zoom.toggle(to: context.actualSize, anchor: tap.location, content: context.content, in: context.bounds)
                }
            )
    }
}
