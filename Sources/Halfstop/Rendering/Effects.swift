import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Develop steps beyond the basic sliders: presence (texture, clarity, dehaze), grain, lens
/// corrections and spot removal. All built from Core Image's own filters, and all sized from the
/// image's long edge so the preview (developed at a lower resolution) looks like the export.
enum Effects {

    // MARK: - Presence

    /// Texture (fine detail), clarity (midtone local contrast) and dehaze, each -100...100.
    static func presence(_ input: CIImage, texture: Double, clarity: Double, dehaze: Double, longEdge: CGFloat) -> CIImage {
        var img = input
        if dehaze != 0 { img = Effects.dehaze(img, amount: dehaze, longEdge: longEdge) }
        if clarity != 0 {
            let radius = longEdge * 0.02
            let boosted = localContrast(img, amount: clarity / 100 * 0.45, radius: radius)
            // Adding contrast at a large radius rings around hard edges (dark bands along a skyline):
            // hold it back right next to strong edges. Softening (negative) has no such problem.
            img = clarity > 0 ? boosted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: awayFromEdges(img, reach: radius),
            ]).cropped(to: img.extent) : boosted
        }
        if texture != 0 { img = localContrast(img, amount: texture / 100 * 0.9, radius: max(1, longEdge * 0.0025)) }
        return img
    }

    /// White away from strong edges, fading to black within `reach` of one.
    static func awayFromEdges(_ input: CIImage, reach: CGFloat) -> CIImage {
        let extent = input.extent
        let lum = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        // Edge strength measured at a scale where noise and fine texture don't count.
        let small = max(1, reach / 16)
        return input.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": lum, "inputGVector": lum, "inputBVector": lum,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(small))
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 15 * small])
            .applyingFilter("CIColorClamp")
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: reach * 0.6])
            .applyingGaussianBlur(sigma: Double(reach * 0.4))
            .applyingFilter("CIColorClamp")
            .applyingFilter("CIColorInvert")
            .cropped(to: extent)
    }

    /// Unsharp masking at `radius`: positive adds contrast at that scale, negative smooths it.
    static func localContrast(_ input: CIImage, amount: Double, radius: CGFloat) -> CIImage {
        let extent = input.extent
        let f = CIFilter.unsharpMask()
        f.inputImage = input.clampedToExtent()
        f.radius = Float(radius)
        f.intensity = Float(amount)
        return (f.outputImage ?? input).cropped(to: extent)
    }

    /// Positive removes haze: subtracts the veil estimated from the darkest channel (haze lifts
    /// every channel, so wherever even the darkest one is bright, there's haze), then restores
    /// the range it took up. Negative adds a soft, bright veil.
    static func dehaze(_ input: CIImage, amount: Double, longEdge: CGFloat) -> CIImage {
        let extent = input.extent
        let d = amount / 100
        if d < 0 {
            let a = CGFloat(-d * 0.45)
            return input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - a, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - a, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: a * 0.7, y: a * 0.72, z: a * 0.75, w: 0),
            ]).cropped(to: extent)
        }
        let own = minChannel(input)
        // Haze varies slowly, so it's estimated over an area, but never more than the pixel's own
        // darkest channel: otherwise dark edges next to bright sky would be pushed to black (halos).
        let dark = own
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(longEdge) * 0.01)
            .applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: own])
            .cropped(to: extent)
        // Veil t = k · dark, capped so the division below stays tame.
        let k = CGFloat(d * 0.75)
        let veil = dark.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]).applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 0.7, y: 0.7, z: 0.7, w: 1)])
        // (I − t) / (1 − t). Subtract and divide both work as background ∘ source.
        let numerator = veil.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: input])
        let denominator = veil.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])
        var out = denominator.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: numerator])
        // Haze also washes out color; give a little back.
        out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + d * 0.2,
                                                                 kCIInputBrightnessKey: 0, kCIInputContrastKey: 1])
        return out.cropped(to: extent)
    }

    /// Gray image of each pixel's smallest channel.
    static func minChannel(_ image: CIImage) -> CIImage {
        func channel(_ v: CIVector) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": v, "inputGVector": v, "inputBVector": v,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        }
        return channel(CIVector(x: 1, y: 0, z: 0, w: 0))
            .applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: channel(CIVector(x: 0, y: 1, z: 0, w: 0))])
            .applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: channel(CIVector(x: 0, y: 0, z: 1, w: 0))])
    }

    // MARK: - Grain

    /// Film-like grain, fixed to the frame (the same photo always gets the same grain). Sized as a
    /// fraction of the frame (`longEdge` is the developed image's), so the preview matches the export.
    static func grain(_ input: CIImage, _ g: Grain, longEdge: CGFloat) -> CIImage {
        guard g.amount > 0 else { return input }
        let extent = input.extent
        // Grain size in output pixels: 1× is one pixel of a 6000-pixel-wide (24-megapixel) frame.
        var grainPixels = CGFloat(g.size) * max(longEdge, 1) / 6000
        var amplitude = CGFloat(g.amount / 100) * 0.28
        // Smaller than a pixel: what a downscale of finer grain would show (averaged, weaker).
        if grainPixels < 1 {
            amplitude *= max(grainPixels, 0.2)
            grainPixels = 1
        }
        let rough = CGFloat(g.roughness / 100)
        guard let random = CIFilter.randomGenerator().outputImage else { return input }
        let a = amplitude * (1 + (1 - rough) * 1.5)
        var noise = random.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.5 - a * 0.5, y: 0.5 - a * 0.5, z: 0.5 - a * 0.5, w: 0),
        ])
        noise = noise.transformed(by: CGAffineTransform(scaleX: grainPixels, y: grainPixels))
        let soften = (1 - rough) * grainPixels * 0.6
        if soften > 0.3 { noise = noise.applyingGaussianBlur(sigma: Double(soften)) }
        return noise.cropped(to: extent)
            .applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: input])
            .cropped(to: extent)
    }

    // MARK: - Lens

    /// Manual lens corrections: color fringing, distortion and vignetting, on the uncropped frame.
    static func lens(_ input: CIImage, _ l: LensCorrection) -> CIImage {
        guard !l.isGeometryNeutral else { return input }
        let extent = input.extent
        var img = input
        if l.removeFringing { img = defringe(img, longEdge: max(extent.width, extent.height)) }
        if l.distortion != 0 {
            let f = CIFilter.bumpDistortion()
            f.inputImage = img.clampedToExtent()
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(hypot(extent.width, extent.height) / 2)
            f.scale = Float(-l.distortion / 100 * 0.3)
            img = (f.outputImage ?? img).cropped(to: extent)
        }
        if l.vignetting != 0 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = img
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(hypot(extent.width, extent.height) * 0.5)
            f.intensity = Float(-l.vignetting / 100 * 0.35)
            f.falloff = 0.5
            img = (f.outputImage ?? img).cropped(to: extent)
        }
        return img
    }

    /// Desaturates purple and green fringes along high-contrast edges.
    static func defringe(_ input: CIImage, longEdge: CGFloat) -> CIImage {
        let extent = input.extent
        // Indexed by display RGB; the weight comes out as is (no color conversion of the result).
        let hue = input.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": WeightCube.dimension, "inputCubeData": WeightCube.data(.fringe),
        ])
        let lum = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let edges = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": lum, "inputGVector": lum, "inputBVector": lum,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]).clampedToExtent()
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 8])
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1, longEdge / 1500)])
            .applyingGaussianBlur(sigma: Double(max(1, longEdge / 2500)))
            .applyingFilter("CIColorClamp")
            .cropped(to: extent)
        let mask = hue.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: edges]).cropped(to: extent)
        let gray = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputBrightnessKey: 0, kCIInputContrastKey: 1])
        return gray.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: input, kCIInputMaskImageKey: mask])
            .cropped(to: extent)
    }

    // MARK: - Spot removal

    /// Replaces each spot with its source area, scaled so its local color and brightness match
    /// the surroundings (so a patch from a slightly darker area still blends in).
    static func removeSpots(_ input: CIImage, _ spots: [Spot]) -> CIImage {
        guard !spots.isEmpty else { return input }
        let extent = input.extent
        let longEdge = max(extent.width, extent.height)
        // Every patch is built from the input (not from earlier patches) and from cropped regions,
        // so each spot only ever touches its own neighbourhood and spots don't stack up per frame.
        let clamped = input.clampedToExtent()
        var img = input
        for spot in spots {
            let r = max(1, CGFloat(spot.radius) * longEdge)
            let c = CGPoint(x: spot.center.x * extent.width, y: (1 - spot.center.y) * extent.height)
            let s = CGPoint(x: spot.source.x * extent.width, y: (1 - spot.source.y) * extent.height)
            let box = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2).integral
            guard box.intersects(extent) else { continue }
            let sigma = Double(r) * 0.9
            // What the blurs below can reach around the spot.
            let reach = box.insetBy(dx: -(r * 0.2 + CGFloat(sigma) * 3), dy: -(r * 0.2 + CGFloat(sigma) * 3))
            let shift = CGAffineTransform(translationX: c.x - s.x, y: c.y - s.y)
            let local = clamped.cropped(to: reach)
            let patch = clamped.cropped(to: reach.applying(shift.inverted())).transformed(by: shift)
            // Color and brightness around the spot vs around the source, leaving out the spot itself
            // (it's what's being removed): wide blurs of both, weighted by a ring outside the spot.
            let ringGradient = CIFilter.radialGradient()
            ringGradient.center = c
            ringGradient.radius0 = Float(r)
            ringGradient.radius1 = Float(r * 1.1)
            ringGradient.color0 = .black
            ringGradient.color1 = .white
            guard let ring = ringGradient.outputImage?.cropped(to: reach) else { continue }
            let around = ring.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: local])
                .applyingGaussianBlur(sigma: sigma)
            let patchAround = ring.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: patch])
                .applyingGaussianBlur(sigma: sigma)
            let ratio = patchAround.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: around])
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.25, y: 0.25, z: 0.25, w: 1),
                                                             "inputMaxComponents": CIVector(x: 4, y: 4, z: 4, w: 1)])
            let healed = ratio.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: patch])
            let g = CIFilter.radialGradient()
            g.center = c
            g.radius0 = Float(r * CGFloat(1 - spot.feather) * 0.95)
            g.radius1 = Float(r)
            g.color0 = .white
            g.color1 = .black
            guard let mask = g.outputImage else { continue }
            let piece = healed.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.clear, kCIInputMaskImageKey: mask,
            ]).cropped(to: box.intersection(extent))
            img = piece.composited(over: img)
        }
        img = img.cropped(to: extent)
        return img
    }
}

// MARK: - Weight cubes

/// Color lookup tables whose output is a gray weight (white = selected), for masks by color.
enum WeightCube {
    static let dimension = 32

    enum Kind: Hashable {
        /// Purple and green, the colors of lens fringing.
        case fringe
        /// Colors near a picked one (display RGB) within a tolerance.
        case near(r: Float, g: Float, b: Float, tolerance: Float)
    }

    private static let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 32
        return c
    }()
    private static let lock = NSLock()

    static func data(_ kind: Kind) -> Data {
        let key = "\(kind)" as NSString
        lock.lock()
        let hit = cache.object(forKey: key)
        lock.unlock()
        if let hit { return hit as Data }
        let d = build(kind)
        lock.lock()
        cache.setObject(d as NSData, forKey: key)
        lock.unlock()
        return d
    }

    private static func build(_ kind: Kind) -> Data {
        let n = dimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        let target: SIMD3<Float>? = {
            if case let .near(r, g, b, _) = kind { return oklab(r, g, b) }
            return nil
        }()
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rr = Float(r) / Float(n - 1), gg = Float(g) / Float(n - 1), bb = Float(b) / Float(n - 1)
                    let w: Float
                    switch kind {
                    case .fringe:
                        let (h, s, l) = ColorLUT.rgbToHSL(rr, gg, bb)
                        let purple = band(h, center: 285, width: 45), green = band(h, center: 115, width: 35)
                        w = max(purple, green) * smoothstep(0.12, 0.3, s) * smoothstep(0.05, 0.15, l)
                    case let .near(_, _, _, tolerance):
                        let lab = oklab(rr, gg, bb)
                        let d = lab - target!
                        // Lightness counts for less than hue, so shading on one object stays selected.
                        let dist = (d.x * d.x * 0.35 + d.y * d.y + d.z * d.z).squareRoot()
                        let tol = max(0.01, tolerance / 100 * 0.3)
                        w = 1 - smoothstep(tol * 0.5, tol, dist)
                    }
                    cube[i] = w; cube[i + 1] = w; cube[i + 2] = w; cube[i + 3] = 1
                    i += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func band(_ h: Float, center: Float, width: Float) -> Float {
        var d = abs(h - center)
        if d > 180 { d = 360 - d }
        return d >= width ? 0 : 0.5 * (1 + cos(Float.pi * d / width))
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Oklab from display (sRGB-encoded) RGB.
    static func oklab(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let lr = lin(r), lg = lin(g), lb = lin(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}

// MARK: - Mask ranges

extension MaskRange {
    /// The weight (white = kept) this range gives each pixel of `base` (a developed, linear image).
    func weight(for base: CIImage) -> CIImage? {
        let extent = base.extent
        let srgb = base.applyingFilter("CILinearToSRGBToneCurve")
        switch kind {
        case .luminance:
            guard !isNeutral else { return nil }
            let v = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
            let s = CGFloat(max(smoothness, 0.01))
            func ramp(scale: CGFloat, bias: CGFloat) -> CIImage {
                let k = CIVector(x: v.x * scale, y: v.y * scale, z: v.z * scale, w: 0)
                return srgb.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": k, "inputGVector": k, "inputBVector": k,
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
                ]).applyingFilter("CIColorClamp")
            }
            var w: CIImage?
            // Rising edge: 0 at low − s, 1 at low. Falling edge: 1 at high, 0 at high + s.
            if low > 0 { w = ramp(scale: 1 / s, bias: 1 - CGFloat(low) / s) }
            if high < 1 {
                let down = ramp(scale: -1 / s, bias: 1 + CGFloat(high) / s)
                w = w.map { down.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? down
            }
            return w?.cropped(to: extent)
        case .color:
            let cube = WeightCube.data(.near(r: Float(red), g: Float(green), b: Float(blue), tolerance: Float(tolerance)))
            // The cube is indexed by display RGB, so feed it the encoded values without conversion.
            return srgb.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": WeightCube.dimension, "inputCubeData": cube,
            ]).cropped(to: extent)
        }
    }
}
