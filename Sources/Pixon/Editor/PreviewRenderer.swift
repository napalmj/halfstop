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
    @ObservationIgnored private var histogramBusy = false
    @ObservationIgnored private var histogramPending: CIImage?
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

    func requestHistogram(_ image: CIImage) {
        if histogramBusy {
            histogramPending = image
            return
        }
        histogramBusy = true
        Task.detached(priority: .utility) {
            let data = Histogram.compute(image)
            await MainActor.run {
                self.histogram = data
                self.histogramBusy = false
                if let next = self.histogramPending {
                    self.histogramPending = nil
                    self.requestHistogram(next)
                }
            }
        }
    }
}

// MARK: - Layout

enum PreviewLayout {
    static let padding: CGFloat = 28

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
    var imageProvider: (() -> CIImage?)?
    var onRendered: ((CIImage) -> Void)?
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
        let image = imageProvider?()
        Self.encode(image, drawableSize: drawableSize, scale: window?.backingScaleFactor ?? 2,
                    background: backgroundColor, colorSpace: colorSpace, pixelFormat: colorPixelFormat,
                    commandBuffer: commandBuffer, texture: { drawable.texture })
        if let image, !image.extent.isEmpty { onRendered?(image) }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Shared by the live view and the offscreen check, so both go through identical code.
    static func encode(_ image: CIImage?, drawableSize: CGSize, scale: CGFloat, background: CIColor,
                       colorSpace: CGColorSpace, pixelFormat: MTLPixelFormat,
                       commandBuffer: MTLCommandBuffer, texture: @escaping () -> MTLTexture) {
        let full = CGRect(origin: .zero, size: drawableSize)
        var composite = CIImage(color: background).cropped(to: full)
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
        }
        let dest = CIRenderDestination(width: Int(drawableSize.width), height: Int(drawableSize.height),
                                       pixelFormat: pixelFormat, commandBuffer: commandBuffer,
                                       mtlTextureProvider: texture)
        dest.colorSpace = colorSpace
        _ = try? Render.preview.startTask(toRender: composite, to: dest)
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
    let provider: () -> CIImage?
    let onRendered: (CIImage) -> Void

    final class Coordinator { var lastToken: AnyHashable? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PreviewMTKView {
        let v = PreviewMTKView()
        v.imageProvider = provider
        v.onRendered = onRendered
        context.coordinator.lastToken = token
        return v
    }

    func updateNSView(_ view: PreviewMTKView, context: Context) {
        view.imageProvider = provider
        view.onRendered = onRendered
        // Only redraw when what's shown actually changed (histogram updates re-run body too).
        if context.coordinator.lastToken != token {
            context.coordinator.lastToken = token
            view.needsDisplay = true
        }
    }
}
