import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import AppKit

enum Render {
    static let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    static let commandQueue: MTLCommandQueue = device.makeCommandQueue()!
    /// GPU context for the live preview (keeps intermediates so RAW decodes are reused).
    static let preview = CIContext(mtlCommandQueue: commandQueue, options: [.cacheIntermediates: true, .name: "pixon.preview"])
    /// Context for thumbnails, histograms and exports.
    static let background = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "pixon.background"])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
}

// MARK: - Thumbnails

final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    private let baseCache = NSCache<NSURL, CGImage>()
    private let editedCache = NSCache<NSString, CGImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 6
        q.qualityOfService = .userInitiated
        return q
    }()
    static let pixelSize: CGFloat = 640

    init() {
        baseCache.countLimit = 2000
        editedCache.countLimit = 2000
    }

    private func key(_ url: URL, _ a: Adjustments) -> NSString {
        "\(url.path)#\(a.hashValue)" as NSString
    }

    func cached(url: URL, adjustments: Adjustments) -> CGImage? {
        if adjustments.isDefault { return baseCache.object(forKey: url as NSURL) }
        return editedCache.object(forKey: key(url, adjustments))
    }

    /// The unedited (embedded/downsampled) image, if already loaded.
    func cachedBase(url: URL) -> CGImage? { baseCache.object(forKey: url as NSURL) }

    func image(url: URL, adjustments: Adjustments) async -> CGImage? {
        if let hit = cached(url: url, adjustments: adjustments) { return hit }
        return await withCheckedContinuation { cont in
            queue.addOperation { [self] in
                cont.resume(returning: render(url: url, adjustments: adjustments))
            }
        }
    }

    private func render(url: URL, adjustments: Adjustments) -> CGImage? {
        let base: CGImage
        if let hit = baseCache.object(forKey: url as NSURL) {
            base = hit
        } else {
            guard let img = ImageSource.downsampled(url: url, maxPixelSize: Self.pixelSize, preferEmbedded: true) else { return nil }
            baseCache.setObject(img, forKey: url as NSURL)
            base = img
        }
        if adjustments.isDefault { return base }
        let k = key(url, adjustments)
        if let hit = editedCache.object(forKey: k) { return hit }
        let out = ImageSource(image: base, url: url).developed(adjustments)
        guard let cg = Render.background.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: Render.sRGB) else { return base }
        editedCache.setObject(cg, forKey: k)
        return cg
    }
}

// MARK: - Histogram

struct HistogramData: Equatable {
    static let bins = 128
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    /// Fraction of pixels clipped in any channel at each end.
    var clippedShadows: Float
    var clippedHighlights: Float
}

enum Histogram {
    static func compute(_ image: CIImage) -> HistogramData? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return nil }
        let scale = min(1, 600 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CILinearToSRGBToneCurve")
        let f = CIFilter.areaHistogram()
        f.inputImage = small
        f.extent = small.extent
        f.count = HistogramData.bins
        f.scale = 1
        guard let out = f.outputImage else { return nil }
        var px = [Float](repeating: 0, count: HistogramData.bins * 4)
        px.withUnsafeMutableBytes { buf in
            Render.background.render(out, toBitmap: buf.baseAddress!, rowBytes: HistogramData.bins * 16,
                                     bounds: CGRect(x: 0, y: 0, width: HistogramData.bins, height: 1),
                                     format: .RGBAf, colorSpace: nil)
        }
        var r = [Float](), g = [Float](), b = [Float]()
        for i in 0..<HistogramData.bins {
            r.append(px[i * 4]); g.append(px[i * 4 + 1]); b.append(px[i * 4 + 2])
        }
        let last = HistogramData.bins - 1
        let clipLow = max(r[0], g[0], b[0])
        let clipHigh = max(r[last], g[last], b[last])
        // Normalize ignoring the end bins so clipping doesn't flatten everything else.
        let peak = max((1..<last).map { max(r[$0], g[$0], b[$0]) }.max() ?? 1, 1e-6)
        func norm(_ a: [Float]) -> [Float] { a.map { min(1, $0 / peak) } }
        return HistogramData(red: norm(r), green: norm(g), blue: norm(b), clippedShadows: clipLow, clippedHighlights: clipHigh)
    }
}

// MARK: - Export

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case jpeg, heic, tiff
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

struct ExportSettings: Codable {
    var format = ExportFormat.jpeg
    var quality = 0.9
    /// Long edge in pixels, 0 = original size.
    var longEdge = 0
    var useDisplayP3 = false
    var destinationPath: String?
}

enum Exporter {
    static func export(_ photo: (url: URL, adjustments: Adjustments), settings: ExportSettings, to folder: URL) throws -> URL {
        guard let source = ImageSource(url: photo.url, maxPixelSize: nil) else {
            throw NSError(domain: "Pixon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not decode \(photo.url.lastPathComponent)"])
        }
        var img = source.developed(photo.adjustments, exporting: true)
        if settings.longEdge > 0 {
            let current = max(img.extent.width, img.extent.height)
            if current > CGFloat(settings.longEdge) {
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = img
                f.scale = Float(CGFloat(settings.longEdge) / current)
                f.aspectRatio = 1
                img = f.outputImage ?? img
                img = img.cropped(to: img.extent.integral)
            }
        }
        let colorSpace = settings.useDisplayP3 ? Render.displayP3 : Render.sRGB
        let stem = photo.url.deletingPathExtension().lastPathComponent
        var dest = folder.appendingPathComponent(stem).appendingPathExtension(settings.format.fileExtension)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(stem)-\(n)").appendingPathExtension(settings.format.fileExtension)
            n += 1
        }
        let ctx = Render.background
        let quality = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): settings.quality]
        switch settings.format {
        case .jpeg:
            try ctx.writeJPEGRepresentation(of: img, to: dest, colorSpace: colorSpace, options: quality)
        case .heic:
            try ctx.writeHEIFRepresentation(of: img, to: dest, format: .RGBA8, colorSpace: colorSpace, options: quality)
        case .tiff:
            try ctx.writeTIFFRepresentation(of: img, to: dest, format: .RGBA16, colorSpace: colorSpace, options: [:])
        }
        return dest
    }
}
