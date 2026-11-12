import Foundation
import CoreImage
import MetalKit
import SwiftUI
import Observation
import ImageIO

/// Owns the decoded preview sources for the editor and produces developed images on demand.
@MainActor
@Observable
final class PreviewRenderer {
    nonisolated static let previewPixelSize: CGFloat = 3200

    private(set) var histogram: HistogramData?
    private(set) var isLoadingFullPreview = false

    @ObservationIgnored private var sources: [URL: ImageSource] = [:]
    @ObservationIgnored private var lru: [URL] = []
    @ObservationIgnored private var inflight: Set<URL> = []
    @ObservationIgnored private var placeholders: [URL: ImageSource] = [:]
    /// Bumped whenever a source finishes loading so views redraw.
    private(set) var generation = 0

    /// Best available source right now: full preview if decoded, else the thumbnail.
    func source(for url: URL) -> ImageSource? {
        if let s = sources[url] { return s }
        if let p = placeholders[url] { return p }
        if let thumb = ThumbnailService.shared.cachedBase(url: url) {
            let p = ImageSource(image: thumb, url: url)
            placeholders[url] = p
            return p
        }
        return nil
    }

    func hasFullSource(_ url: URL) -> Bool { sources[url] != nil }

    /// The image the live preview draws for a frame (shared with `--bench`).
    ///
    /// Develops at the resolution the image actually occupies on screen rather than the
    /// full decoded preview size: every filter then touches only the pixels you can see.
    nonisolated static func previewImage(_ source: ImageSource, _ a: Adjustments, geometry: GeometryMode, overlayMask: UUID?,
                                         drawableSize: CGSize, scale: CGFloat) -> CIImage {
        source.developed(a, geometry: geometry, overlayMask: overlayMask,
                         renderScale: renderScale(source: source, a, geometry: geometry, drawableSize: drawableSize, scale: scale))
    }

    /// Fraction of the decoded source's resolution needed to fill the on-screen image rect,
    /// quantized so small window resizes don't keep invalidating cached intermediates.
    nonisolated static func renderScale(source: ImageSource, _ a: Adjustments, geometry: GeometryMode,
                                        drawableSize: CGSize, scale: CGFloat) -> CGFloat {
        guard source.size.width > 0, drawableSize.width > 0, scale > 0 else { return 1 }
        let content = PreviewLayout.contentSize(source.size, a, geometry)
        let rect = PreviewLayout.fit(content, in: CGSize(width: drawableSize.width / scale, height: drawableSize.height / scale))
        guard content.width > 0, rect.width > 0 else { return 1 }
        let needed = rect.width * scale / content.width
        let step: CGFloat = 1 / 16
        return min(1, max(step, (needed / step).rounded(.up) * step))
    }

    /// Forces a redraw (e.g. a subject mask finished detecting).
    func bump() { generation += 1 }

    /// Ensures the given photo (and its neighbors, at lower priority) get decoded.
    func prepare(_ url: URL, neighbors: [URL]) {
        load(url, priority: .userInitiated)
        for n in neighbors { load(n, priority: .utility) }
        isLoadingFullPreview = sources[url] == nil
    }

    private func load(_ url: URL, priority: TaskPriority) {
        if sources[url] != nil {
            touch(url)
            return
        }
        guard !inflight.contains(url) else { return }
        inflight.insert(url)
        if placeholders[url] == nil {
            Task.detached(priority: priority) {
                _ = await ThumbnailService.shared.image(url: url, adjustments: Adjustments())
                await MainActor.run { self.generation += 1 }
            }
        }
        Task.detached(priority: priority) {
            let source = ImageSource(url: url, maxPixelSize: PreviewRenderer.previewPixelSize)
            // Force the expensive decode off the main thread.
            if let source { _ = source.developed(Adjustments()).extent }
            await MainActor.run {
                self.inflight.remove(url)
                if let source {
                    self.sources[url] = source
                    self.placeholders[url] = nil
                    self.touch(url)
                    self.evict()
                }
                self.isLoadingFullPreview = false
                self.generation += 1
            }
        }
    }

    private func touch(_ url: URL) {
        lru.removeAll { $0 == url }
        lru.append(url)
    }

    private func evict() {
        while lru.count > 5 {
            let old = lru.removeFirst()
            sources[old] = nil
        }
    }

    func clear() {
        sources = [:]
        placeholders = [:]
        lru = []
        histogram = nil
    }

    /// Size of the area the image occupies on screen (crop mode shows the straightened frame).
    func displaySize(for url: URL, adjustments: Adjustments, cropping: Bool) -> CGSize? {
        guard let s = source(for: url) else { return nil }
        if cropping {
            return ImageSource.straightenedFrameSize(size: s.size, angle: adjustments.crop.angle)
        }
        let frame = ImageSource.straightenedFrameSize(size: s.size, angle: adjustments.crop.angle)
        let r = adjustments.crop.rect
        return CGSize(width: frame.width * r.width, height: frame.height * r.height)
    }

    // MARK: - Histogram

    @ObservationIgnored private var histogramLatest: HistogramData?
    @ObservationIgnored private var histogramScheduled = false

    /// Takes the histogram of a frame that was just drawn. Publishes at most ~15 times a
    /// second (always ending on the latest frame) so the panel doesn't re-render per frame.
    func receiveHistogram(_ data: HistogramData) {
        histogramLatest = data
        guard !histogramScheduled else { return }
        histogramScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 15) { [weak self] in
            guard let self else { return }
            self.histogramScheduled = false
            if let latest = self.histogramLatest, latest != self.histogram { self.histogram = latest }
        }
    }
}

// MARK: - Layout

enum PreviewLayout {
    static let padding: CGFloat = 28

    /// Size of what's drawn for a source of `size` (the straightened frame while cropping,
    /// the uncropped photo while editing a mask, else the crop).
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

    /// Where an image of `content` size sits inside `bounds` (top-left origin, points).
    static func fit(_ content: CGSize, in bounds: CGSize, padding: CGFloat = padding) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let avail = CGSize(width: max(bounds.width - padding * 2, 1), height: max(bounds.height - padding * 2, 1))
        let s = min(avail.width / content.width, avail.height / content.height)
        let size = CGSize(width: content.width * s, height: content.height * s)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

// MARK: - Metal view

final class PreviewMTKView: MTKView {
    /// Called with the drawable size (pixels) and backing scale.
    var imageProvider: ((CGSize, CGFloat) -> CIImage?)?
    /// When set, gets the histogram of each drawn frame (main thread).
    var onHistogram: ((HistogramData) -> Void)?
    var backgroundColor = CIColor(red: 0.09, green: 0.09, blue: 0.095)
    private let colorSpace = Render.displayP3

    init() {
        super.init(frame: .zero, device: Render.device)
        framebufferOnly = false
        enableSetNeedsDisplay = true
        isPaused = true
        autoResizeDrawable = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.095, alpha: 1)
        (layer as? CAMetalLayer)?.colorspace = colorSpace
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable,
              let commandBuffer = Render.commandQueue.makeCommandBuffer() else { return }
        let scale = window?.backingScaleFactor ?? 2
        let image = imageProvider?(drawableSize, scale)
        let rect = Self.encode(image, drawableSize: drawableSize, scale: scale,
                               background: backgroundColor, colorSpace: colorSpace, pixelFormat: colorPixelFormat,
                               commandBuffer: commandBuffer, texture: { drawable.texture })
        // Histogram of the pixels just drawn: no second trip through the develop pipeline.
        if let onHistogram, let rect,
           let readback = HistogramReadback(source: drawable.texture, rect: rect, commandBuffer: commandBuffer) {
            commandBuffer.addCompletedHandler { _ in
                guard let data = readback.read() else { return }
                DispatchQueue.main.async { onHistogram(data) }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Shared by the live view, the benchmark and the offscreen check, so all go through identical code.
    /// Returns where the image landed in the drawable (pixels, Metal's top-left origin), if anything was drawn.
    @discardableResult
    static func encode(_ image: CIImage?, drawableSize: CGSize, scale: CGFloat, background: CIColor,
                       colorSpace: CGColorSpace, pixelFormat: MTLPixelFormat,
                       commandBuffer: MTLCommandBuffer, texture: @escaping () -> MTLTexture) -> CGRect? {
        let full = CGRect(origin: .zero, size: drawableSize)
        var composite = CIImage(color: background).cropped(to: full)
        var placedRect: CGRect?
        if let image, !image.extent.isEmpty, image.extent.width.isFinite {
            let rectPts = PreviewLayout.fit(image.extent.size, in: CGSize(width: drawableSize.width / scale, height: drawableSize.height / scale))
            let rect = CGRect(x: rectPts.minX * scale, y: drawableSize.height - rectPts.maxY * scale,
                              width: rectPts.width * scale, height: rectPts.height * scale)
            let s = rect.width / image.extent.width
            let placed = image
                .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            composite = placed.composited(over: composite)
            placedRect = CGRect(x: rect.minX, y: drawableSize.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let dest = CIRenderDestination(width: Int(drawableSize.width), height: Int(drawableSize.height),
                                       pixelFormat: pixelFormat, commandBuffer: commandBuffer,
                                       mtlTextureProvider: texture)
        dest.colorSpace = colorSpace
        _ = try? Render.preview.startTask(toRender: composite, to: dest)
        return placedRect
    }

    /// Renders through the live-view path into a readable texture and saves a PNG (orientation check).
    static func renderOffscreen(_ image: CIImage, size: CGSize, to url: URL) -> Bool {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        desc.usage = [.shaderWrite, .renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = Render.device.makeTexture(descriptor: desc),
              let cb = Render.commandQueue.makeCommandBuffer() else { return false }
        encode(image, drawableSize: size, scale: 1, background: CIColor(red: 0.09, green: 0.09, blue: 0.095),
               colorSpace: Render.sRGB, pixelFormat: .bgra8Unorm, commandBuffer: cb, texture: { tex })
        cb.commit()
        cb.waitUntilCompleted()
        let w = Int(size.width), h = Int(size.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: Render.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }
}

struct PreviewImageView: NSViewRepresentable {
    /// Changes to this value trigger a redraw.
    let token: AnyHashable
    let provider: (CGSize, CGFloat) -> CIImage?
    /// nil = don't take histograms (e.g. while the red mask overlay is showing).
    let onHistogram: ((HistogramData) -> Void)?

    final class Coordinator { var lastToken: AnyHashable? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PreviewMTKView {
        let v = PreviewMTKView()
        v.imageProvider = provider
        v.onHistogram = onHistogram
        context.coordinator.lastToken = token
        return v
    }

    func updateNSView(_ view: PreviewMTKView, context: Context) {
        view.imageProvider = provider
        view.onHistogram = onHistogram
        // Only redraw when what's shown actually changed (histogram updates re-run body too).
        if context.coordinator.lastToken != token {
            context.coordinator.lastToken = token
            view.needsDisplay = true
        }
    }
}
