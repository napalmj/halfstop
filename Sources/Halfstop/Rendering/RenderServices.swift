import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import AppKit
import ImageIO
import CryptoKit

enum Render {
    static let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    static let commandQueue: MTLCommandQueue = device.makeCommandQueue()!
    /// GPU context for the live preview (keeps intermediates so RAW decodes are reused).
    static let preview = CIContext(mtlCommandQueue: commandQueue, options: [.cacheIntermediates: true, .name: "halfstop.preview"])
    /// Context for thumbnails, histograms and exports.
    static let background = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "halfstop.background"])
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
        // By bytes too: 2000 thumbnails at 640 px would otherwise be ~2 GB.
        baseCache.totalCostLimit = 400 << 20
        editedCache.totalCostLimit = 250 << 20
    }

    private static func cost(_ img: CGImage) -> Int { img.bytesPerRow * img.height }

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
        let disk = ThumbnailDiskCache.shared
        let base: CGImage
        if let hit = baseCache.object(forKey: url as NSURL) {
            base = hit
        } else {
            let diskKey = disk.key(url: url, adjustments: nil)
            if let k = diskKey, let hit = disk.load(k) {
                base = hit
            } else {
                guard let img = ImageSource.downsampled(url: url, maxPixelSize: Self.pixelSize, preferEmbedded: true) else { return nil }
                if let k = diskKey { disk.store(img, key: k) }
                base = img
            }
            baseCache.setObject(base, forKey: url as NSURL, cost: Self.cost(base))
        }
        if adjustments.isDefault { return base }
        let k = key(url, adjustments)
        if let hit = editedCache.object(forKey: k) { return hit }
        // Subject masks can't be detected on a thumbnail, so those renders aren't final: keep them in memory only.
        let diskKey = adjustments.masks.contains { $0.kind == .subject } ? nil : disk.key(url: url, adjustments: adjustments)
        if let dk = diskKey, let hit = disk.load(dk) {
            editedCache.setObject(hit, forKey: k, cost: Self.cost(hit))
            return hit
        }
        let out = ImageSource(image: base, url: url).developed(adjustments)
        guard let cg = Render.background.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: Render.sRGB) else { return base }
        editedCache.setObject(cg, forKey: k, cost: Self.cost(cg))
        if let dk = diskKey { disk.store(cg, key: dk) }
        return cg
    }
}

/// Thumbnails kept between launches in `~/Library/Caches/Halfstop/Thumbnails`, so the grid doesn't
/// re-extract every RAW preview and re-develop every edited thumbnail at each start.
/// Keyed by the file (path, size, modification date) and the exact adjustments.
final class ThumbnailDiskCache: @unchecked Sendable {
    static let shared = ThumbnailDiskCache()
    /// Overridable for tests.
    nonisolated(unsafe) static var directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Halfstop/Thumbnails", isDirectory: true)
    static let maxBytes: Int64 = 1 << 30

    private let writes = DispatchQueue(label: "halfstop.thumbcache", qos: .utility)

    init() {
        writes.async { Self.trim() }
    }

    func key(url: URL, adjustments: Adjustments?) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        var data = Data("\(url.path)|\(size)|\(mtime)|\(ThumbnailService.pixelSize)|".utf8)
        if let adjustments {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let json = try? encoder.encode(adjustments) else { return nil }
            data.append(json)
        }
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ key: String) -> URL {
        Self.directory.appendingPathComponent(String(key.prefix(2)), isDirectory: true).appendingPathComponent(key + ".jpg")
    }

    func load(_ key: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(file(key) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func store(_ image: CGImage, key: String) {
        let dest = file(key)
        writes.async {
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = dest.appendingPathExtension("tmp")
            guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(d) {
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.moveItem(at: tmp, to: dest)
            }
        }
    }

    /// Wait for pending writes (tests).
    func flush() { writes.sync {} }

    /// Keeps the cache under `maxBytes`, dropping the least recently written thumbnails.
    static func trim() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files: [(URL, Int64, Date)] = []
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = v.fileSize else { continue }
            files.append((u, Int64(size), v.contentModificationDate ?? .distantPast))
            total += Int64(size)
        }
        guard total > maxBytes else { return }
        for (u, size, _) in files.sorted(by: { $0.2 < $1.2 }) {
            try? fm.removeItem(at: u)
            total -= size
            if total <= maxBytes * 3 / 4 { break }
        }
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
    /// Histogram of a developed (linear) image; renders it, so only for one-off use (tests).
    static func compute(_ image: CIImage) -> HistogramData? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return nil }
        let scale = min(1, 600 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CILinearToSRGBToneCurve")
        guard let out = areaHistogram(small, extent: small.extent) else { return nil }
        var px = [Float](repeating: 0, count: HistogramData.bins * 4)
        px.withUnsafeMutableBytes { buf in
            Render.background.render(out, toBitmap: buf.baseAddress!, rowBytes: HistogramData.bins * 16,
                                     bounds: CGRect(x: 0, y: 0, width: HistogramData.bins, height: 1),
                                     format: .RGBAf, colorSpace: nil)
        }
        return make(px)
    }

    static func areaHistogram(_ image: CIImage, extent: CGRect) -> CIImage? {
        let f = CIFilter.areaHistogram()
        f.inputImage = image
        f.extent = extent
        f.count = HistogramData.bins
        f.scale = 1
        return f.outputImage
    }

    /// Normalizes raw RGBA bin values (`bins * 4` floats).
    static func make(_ px: [Float]) -> HistogramData {
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

/// Takes the histogram of pixels already rendered into a texture (the live preview's drawable),
/// encoded into the same command buffer, so it costs a small GPU pass instead of re-developing
/// the photo. Call `read()` once the command buffer has completed.
final class HistogramReadback: @unchecked Sendable {
    private let output: MTLTexture

    /// `rect` is in the texture's pixels, top-left origin.
    init?(source: MTLTexture, rect: CGRect, commandBuffer: MTLCommandBuffer) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: HistogramData.bins, height: 1, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        desc.storageMode = .shared
        guard rect.width >= 1, rect.height >= 1,
              let output = Render.device.makeTexture(descriptor: desc),
              // The drawable already holds display-encoded values, so no tone curve is needed.
              var image = CIImage(mtlTexture: source, options: [.colorSpace: NSNull()]) else { return nil }
        self.output = output
        // CIImage(mtlTexture:) has a bottom-left origin.
        let region = CGRect(x: rect.minX, y: CGFloat(source.height) - rect.maxY, width: rect.width, height: rect.height).integral
            .intersection(image.extent)
        let s = min(1, 512 / max(region.width, region.height))
        image = image.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        let small = CGRect(x: 0, y: 0, width: floor(region.width * s), height: floor(region.height * s))
        guard small.width >= 1, small.height >= 1,
              let hist = Histogram.areaHistogram(image, extent: small) else { return nil }
        let dest = CIRenderDestination(mtlTexture: output, commandBuffer: commandBuffer)
        dest.colorSpace = nil
        guard (try? Render.preview.startTask(toRender: hist, to: dest)) != nil else { return nil }
    }

    func read() -> HistogramData? {
        var px = [Float](repeating: 0, count: HistogramData.bins * 4)
        output.getBytes(&px, bytesPerRow: HistogramData.bins * 16, from: MTLRegionMake2D(0, 0, HistogramData.bins, 1), mipmapLevel: 0)
        return Histogram.make(px)
    }
}

// MARK: - Clipping

/// Marks pixels the display can't show: red where any channel is blown (≥ 1),
/// blue where every channel is crushed to black.
enum ClippingOverlay {
    static let highlight: CGFloat = 0.995
    /// Linear value of about 1/255 after sRGB encoding.
    static let shadow: CGFloat = 0.0004

    static func apply(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard !e.isEmpty, e.width.isFinite else { return image }
        // Brightest channel of each pixel, as gray.
        func channel(_ v: CIVector) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": v, "inputGVector": v, "inputBVector": v,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        }
        let maxChannel = channel(CIVector(x: 1, y: 0, z: 0, w: 0))
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(CIVector(x: 0, y: 1, z: 0, w: 0))])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(CIVector(x: 0, y: 0, z: 1, w: 0))])
        let blown = maxChannel.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": highlight])
        let crushed = maxChannel.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": shadow])
            .applyingFilter("CIColorInvert")
        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: e)
        let blue = CIImage(color: CIColor(red: 0.15, green: 0.35, blue: 1)).cropped(to: e)
        var out = red.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: blown])
        out = blue.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: crushed])
        return out.cropped(to: e)
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
    /// Copy the original's EXIF/IPTC/TIFF metadata (camera, lens, capture time, copyright…).
    var keepMetadata = true
    /// Leave out GPS location even when keeping metadata.
    var stripLocation = false

    init() {}

    /// Tolerant, so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportSettings()
        format = (try? c.decodeIfPresent(ExportFormat.self, forKey: .format)) ?? d.format
        quality = (try? c.decodeIfPresent(Double.self, forKey: .quality)) ?? d.quality
        longEdge = (try? c.decodeIfPresent(Int.self, forKey: .longEdge)) ?? d.longEdge
        useDisplayP3 = (try? c.decodeIfPresent(Bool.self, forKey: .useDisplayP3)) ?? d.useDisplayP3
        destinationPath = try? c.decodeIfPresent(String.self, forKey: .destinationPath)
        keepMetadata = (try? c.decodeIfPresent(Bool.self, forKey: .keepMetadata)) ?? d.keepMetadata
        stripLocation = (try? c.decodeIfPresent(Bool.self, forKey: .stripLocation)) ?? d.stripLocation
    }
}

enum Exporter {
    static func export(_ photo: (url: URL, adjustments: Adjustments), settings: ExportSettings, to folder: URL) throws -> URL {
        if let n = ImageSource.declaredPixelCount(url: photo.url), n > Double(ImageSource.maxFullSizePixels) {
            throw NSError(domain: "Halfstop", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "\(photo.url.lastPathComponent) is too large to export (\(Int(n / 1_000_000)) megapixels; the limit is \(ImageSource.maxFullSizePixels / 1_000_000))"])
        }
        guard let source = ImageSource(url: photo.url, maxPixelSize: nil) else {
            throw NSError(domain: "Halfstop", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not decode \(photo.url.lastPathComponent)"])
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
        if settings.keepMetadata {
            img = img.settingProperties(metadata(of: photo.url, stripLocation: settings.stripLocation))
        } else {
            img = img.settingProperties([:])
        }
        let colorSpace = settings.useDisplayP3 ? Render.displayP3 : Render.sRGB
        let dest = reserveName(for: photo.url, format: settings.format, in: folder)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: dest) } }
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
        finished = true
        return dest
    }

    /// Exports several photos, `concurrency` at a time (each full-size decode is large, so not more).
    /// Stops starting new ones when the task is cancelled. Results are in `jobs` order.
    static func exportAll(_ jobs: [(url: URL, adjustments: Adjustments)], settings: ExportSettings, to folder: URL,
                          concurrency: Int, progress: @escaping @Sendable (Int) async -> Void) async -> [(url: URL, result: Result<URL, Error>)] {
        var results = [(url: URL, result: Result<URL, Error>)?](repeating: nil, count: jobs.count)
        await withTaskGroup(of: (Int, Result<URL, Error>).self) { group in
            var next = 0, finished = 0
            func start() {
                guard next < jobs.count, !Task.isCancelled else { return }
                let i = next, job = jobs[i]
                next += 1
                group.addTask(priority: .userInitiated) {
                    (i, Result { try Exporter.export(job, settings: settings, to: folder) })
                }
            }
            for _ in 0..<max(1, concurrency) { start() }
            for await (i, r) in group {
                results[i] = (jobs[i].url, r)
                finished += 1
                await progress(finished)
                start()
            }
        }
        return results.compactMap { $0 }
    }

    private static let nameLock = NSLock()

    /// Picks an unused name (`stem`, `stem-1`, …) and claims it with an empty file, so exports
    /// running side by side never pick the same one.
    static func reserveName(for photo: URL, format: ExportFormat, in folder: URL) -> URL {
        nameLock.lock(); defer { nameLock.unlock() }
        let stem = photo.deletingPathExtension().lastPathComponent
        var dest = folder.appendingPathComponent(stem).appendingPathExtension(format.fileExtension)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(stem)-\(n)").appendingPathExtension(format.fileExtension)
            n += 1
        }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        return dest
    }

    /// The original's metadata, minus what no longer applies to the developed pixels
    /// (orientation is baked in; size and color profile are the export's own).
    static func metadata(of url: URL, stripLocation: Bool) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        for key in [kCGImagePropertyOrientation, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
                    kCGImagePropertyDepth, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
                    kCGImagePropertyHasAlpha, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
                    kCGImagePropertyRawDictionary, kCGImagePropertyDNGDictionary,
                    kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
                    kCGImagePropertyMakerFujiDictionary, kCGImagePropertyMakerOlympusDictionary,
                    kCGImagePropertyMakerPentaxDictionary, kCGImagePropertyMakerMinoltaDictionary] {
            props[key as String] = nil
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = nil
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = nil
            exif[kCGImagePropertyExifPixelYDimension as String] = nil
            props[kCGImagePropertyExifDictionary as String] = exif
        }
        if stripLocation { props[kCGImagePropertyGPSDictionary as String] = nil }
        props[kCGImagePropertyOrientation as String] = 1
        return props
    }
}
