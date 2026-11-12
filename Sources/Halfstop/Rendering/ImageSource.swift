import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

enum GeometryMode {
    /// Straighten and crop (final look).
    case full
    /// Straighten only — what the crop tool draws its overlay on top of.
    case straightenOnly
    /// No straighten or crop — used while drawing masks, whose geometry is in uncropped space.
    case none
}

/// A decoded photo that can be "developed" with a set of adjustments.
///
/// Not thread-safe: a RAW source wraps a mutable `CIRAWFilter`, so each consumer
/// (the live preview, an export job) owns its own instance.
final class ImageSource {
    let url: URL
    let isRAW: Bool
    /// A stand-in decoded from the thumbnail; its geometry may not match the real photo.
    let isProxy: Bool
    private let raw: CIRAWFilter?
    private let base: CIImage?
    private let asShotTemperature: Float
    private let asShotTint: Float
    private let defaultNoiseReduction: Float
    /// Oriented pixel size of the undeveloped image at the scale it was loaded.
    let size: CGSize

    /// Loads a photo. `maxPixelSize` downsamples for fast previews; nil means full resolution.
    init?(url: URL, maxPixelSize: CGFloat?) {
        self.url = url
        let ext = url.pathExtension.lowercased()
        if ImageFormats.raw.contains(ext), let raw = CIRAWFilter(imageURL: url) {
            if let maxPixelSize {
                let native = raw.nativeSize
                let longEdge = max(native.width, native.height)
                if longEdge > maxPixelSize { raw.scaleFactor = Float(maxPixelSize / longEdge) }
            }
            if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = true }
            self.raw = raw
            self.base = nil
            self.isRAW = true
            self.isProxy = false
            self.asShotTemperature = raw.neutralTemperature
            self.asShotTint = raw.neutralTint
            self.defaultNoiseReduction = raw.luminanceNoiseReductionAmount
            guard let out = raw.outputImage else { return nil }
            self.size = out.extent.size
        } else {
            let image: CIImage?
            if let maxPixelSize {
                image = ImageSource.downsampled(url: url, maxPixelSize: maxPixelSize).map { CIImage(cgImage: $0) }
            } else {
                image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            }
            guard let image else { return nil }
            let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            self.raw = nil
            self.base = normalized
            self.isRAW = false
            self.isProxy = false
            self.asShotTemperature = 6500
            self.asShotTint = 0
            self.defaultNoiseReduction = 0
            self.size = normalized.extent.size
        }
    }

    /// Wraps an already-decoded image (used for thumbnails).
    init(image: CGImage, url: URL) {
        self.url = url
        self.raw = nil
        self.base = CIImage(cgImage: image)
        self.isRAW = false
        self.isProxy = true
        self.asShotTemperature = 6500
        self.asShotTint = 0
        self.defaultNoiseReduction = 0
        self.size = CGSize(width: image.width, height: image.height)
    }

    // MARK: - Develop

    /// - Parameters:
    ///   - overlayMask: draws this mask as a red overlay (for the mask tools).
    ///   - exporting: detect subjects synchronously instead of skipping them while pending.
    ///   - renderScale: develop at this fraction of the source's resolution (the live preview
    ///     passes what fits on screen). Radii and masks scale with the image, so the look holds.
    func developed(_ a: Adjustments, geometry: GeometryMode = .full, overlayMask: UUID? = nil, exporting: Bool = false,
                   renderScale: CGFloat = 1) -> CIImage {
        var img: CIImage
        if let raw {
            raw.exposure = Float(a.exposure)
            raw.neutralTemperature = asShotTemperature * pow(2, Float(a.temperature / 100) * 0.7)
            raw.neutralTint = asShotTint + Float(a.tint) * 1.2
            if raw.isLuminanceNoiseReductionSupported {
                let amount = Float(a.noiseReduction / 100)
                raw.luminanceNoiseReductionAmount = defaultNoiseReduction + (1 - defaultNoiseReduction) * amount
            }
            img = raw.outputImage ?? CIImage.empty()
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            img = Self.downscaled(img, renderScale)
        } else {
            img = Self.downscaled(base ?? CIImage.empty(), renderScale)
            if a.temperature != 0 || a.tint != 0 {
                let f = CIFilter.temperatureAndTint()
                f.inputImage = img
                f.neutral = CIVector(x: 6500, y: 0)
                f.targetNeutral = CIVector(x: 6500 * pow(2, -a.temperature / 100 * 0.7), y: -a.tint * 1.2)
                img = f.outputImage ?? img
            }
            if a.exposure != 0 {
                let f = CIFilter.exposureAdjust()
                f.inputImage = img
                f.ev = Float(a.exposure)
                img = f.outputImage ?? img
            }
            if a.noiseReduction > 0 {
                let f = CIFilter.noiseReduction()
                f.inputImage = img
                f.noiseLevel = Float(a.noiseReduction / 100 * 0.06)
                f.sharpness = 0.4
                img = f.outputImage ?? img
            }
        }
        let extent = img.extent
        let longEdge = max(extent.width, extent.height)

        // Local highlight recovery + shadow lift.
        if a.highlights < 0 || a.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.highlightAmount = Float(1 + min(0, a.highlights) / 100)
            f.shadowAmount = Float(a.shadows / 100)
            f.radius = Float(longEdge / 200)
            img = (f.outputImage ?? img).cropped(to: extent)
        }

        // Tone + curve + HSL, all in one lookup.
        let lutKey = ColorLUTKey(a)
        if !lutKey.isIdentity {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img
            f.cubeDimension = Float(ColorLUT.dimension)
            f.cubeData = ColorLUT.cubeData(for: lutKey)
            f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            img = f.outputImage ?? img
        }

        if a.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = img
            f.amount = Float(a.vibrance / 100)
            img = f.outputImage ?? img
        }
        if a.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.saturation = Float(1 + a.saturation / 100)
            f.brightness = 0
            f.contrast = 1
            img = f.outputImage ?? img
        }
        // Local adjustments, each blended through its mask.
        var overlay: CIImage?
        for mask in a.masks where mask.enabled {
            let needsApply = !mask.local.isNeutral
            let wantsOverlay = mask.id == overlayMask
            guard needsApply || wantsOverlay else { continue }
            guard let m = MaskRenderer.image(for: mask, size: extent.size, url: url, base: img,
                                             canDetect: !isProxy, exporting: exporting) else { continue }
            if needsApply {
                let local = ImageSource.applyLocal(mask.local, to: img, longEdge: longEdge)
                img = local.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: m,
                ]).cropped(to: extent)
            }
            if wantsOverlay { overlay = m }
        }
        if let overlay {
            let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.15, alpha: 0.55)).cropped(to: extent)
            let tinted = red.composited(over: img)
            img = tinted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: overlay,
            ]).cropped(to: extent)
        }

        if a.sharpening > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img
            f.sharpness = Float(a.sharpening / 100 * 1.2)
            f.radius = Float(max(0.6, longEdge / 3000 * 1.5))
            img = (f.outputImage ?? img).cropped(to: extent)
        }

        if geometry != .none {
            img = ImageSource.applyGeometry(img, crop: a.crop, mode: geometry)
        }

        if a.vignette != 0 {
            let e = img.extent
            let f = CIFilter.vignetteEffect()
            f.inputImage = img
            f.center = CGPoint(x: e.midX, y: e.midY)
            f.radius = Float(hypot(e.width, e.height) * 0.5 * 0.85)
            f.intensity = Float(-a.vignette / 100)
            f.falloff = 0.7
            img = (f.outputImage ?? img).cropped(to: e)
        }
        return img
    }

    /// Scales an origin-at-zero image down (bilinear for mild reductions, Lanczos below half
    /// size where bilinear would alias), cropped to whole pixels.
    static func downscaled(_ image: CIImage, _ scale: CGFloat) -> CIImage {
        guard scale < 0.999, scale > 0, !image.extent.isEmpty, image.extent.width.isFinite else { return image }
        let out: CIImage
        // Clamp first so edge pixels don't blend with transparency.
        let clamped = image.clampedToExtent()
        if scale >= 0.5 {
            out = clamped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = clamped
            f.scale = Float(scale)
            f.aspectRatio = 1
            out = f.outputImage ?? clamped
        }
        let size = image.extent.size
        return out.cropped(to: CGRect(x: 0, y: 0, width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale))))
    }

    /// The subset of develop steps a mask can apply locally.
    static func applyLocal(_ l: LocalAdjustments, to input: CIImage, longEdge: CGFloat) -> CIImage {
        let extent = input.extent
        var img = input
        if l.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(l.exposure)
            img = f.outputImage ?? img
        }
        if l.temperature != 0 || l.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 * pow(2, -l.temperature / 100 * 0.7), y: -l.tint * 1.2)
            img = f.outputImage ?? img
        }
        if l.highlights < 0 || l.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.highlightAmount = Float(1 + min(0, l.highlights) / 100)
            f.shadowAmount = Float(l.shadows / 100)
            f.radius = Float(longEdge / 200)
            img = (f.outputImage ?? img).cropped(to: extent)
        }
        let key = ColorLUTKey(local: l)
        if !key.isIdentity {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img
            f.cubeDimension = Float(ColorLUT.dimension)
            f.cubeData = ColorLUT.cubeData(for: key)
            f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            img = f.outputImage ?? img
        }
        if l.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = img
            f.amount = Float(l.vibrance / 100)
            img = f.outputImage ?? img
        }
        if l.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.saturation = Float(1 + l.saturation / 100)
            f.brightness = 0
            f.contrast = 1
            img = f.outputImage ?? img
        }
        return img
    }

    // MARK: - Geometry

    /// Scale needed so a rotated w×h image still covers its original w×h frame.
    static func straightenScale(size: CGSize, angle: Double) -> Double {
        let t = abs(angle) * .pi / 180
        guard t > 0 else { return 1 }
        let w = size.width, h = size.height
        return max((w * cos(t) + h * sin(t)) / w, (w * sin(t) + h * cos(t)) / h)
    }

    /// Size of the straightened (auto-cropped) frame the crop rect lives in.
    static func straightenedFrameSize(size: CGSize, angle: Double) -> CGSize {
        let k = straightenScale(size: size, angle: angle)
        return CGSize(width: size.width / k, height: size.height / k)
    }

    static func applyGeometry(_ image: CIImage, crop: CropSettings, mode: GeometryMode) -> CIImage {
        guard !crop.isIdentity else { return image }
        let e = image.extent
        var img = image
        if crop.angle != 0 {
            let c = CGPoint(x: e.midX, y: e.midY)
            let t = CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: -crop.angle * .pi / 180)
                .translatedBy(x: -c.x, y: -c.y)
            img = img.clampedToExtent().transformed(by: t)
        }
        let frameSize = straightenedFrameSize(size: e.size, angle: crop.angle)
        let frame = CGRect(x: e.midX - frameSize.width / 2, y: e.midY - frameSize.height / 2,
                           width: frameSize.width, height: frameSize.height)
        var target = frame
        if mode == .full {
            let r = crop.rect
            target = CGRect(x: frame.minX + r.minX * frame.width,
                            y: frame.minY + (1 - r.maxY) * frame.height,
                            width: r.width * frame.width,
                            height: r.height * frame.height)
        }
        target = target.integral.intersection(frame.integral)
        img = img.cropped(to: target)
        return img.transformed(by: CGAffineTransform(translationX: -target.minX, y: -target.minY))
    }

    // MARK: - Thumbnails

    static func downsampled(url: URL, maxPixelSize: CGFloat, preferEmbedded: Bool = false) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if preferEmbedded {
            opts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            // Embedded RAW previews are sometimes tiny; fall back to a real decode.
            if preferEmbedded, max(img.width, img.height) < Int(maxPixelSize) / 2 {
                opts.removeValue(forKey: kCGImageSourceCreateThumbnailFromImageIfAbsent)
                opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? img
            }
            return img
        }
        return nil
    }
}
