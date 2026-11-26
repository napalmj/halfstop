import SwiftUI
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Metal

/// Headless checks for the develop pipeline: `Halfstop --selftest <output-dir>`.
/// Also `Halfstop --make-samples <dir>` writes synthetic test photos.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--make-samples"), i + 1 < args.count {
            makeSamples(in: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            // The test deletes and recreates folders inside `dir`: never let it loose on one it didn't make.
            guard TestOutput.claim(dir) else {
                print("--selftest: \(dir.path) isn't empty and wasn't made by a test run. Choose a new or empty folder.")
                exit(2)
            }
            // Keep test thumbnails out of the real cache.
            ThumbnailDiskCache.directory = dir.appendingPathComponent("thumbcache", isDirectory: true)
            try? FileManager.default.removeItem(at: ThumbnailDiskCache.directory)
            // Vision's output isn't part of the test: faces and horizons come from the test hook.
            AutoVision.shared.visionEnabled = false
            let pipelineOK = run(dir: dir)
            var libraryOK = false
            var done = false
            Task { @MainActor in
                libraryOK = await LibraryTest.run(dir: dir.appendingPathComponent("library"))
                done = true
            }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            print(pipelineOK && libraryOK ? "EVERYTHING PASSED" : "FAILURES ABOVE")
            exit(pipelineOK && libraryOK ? 0 : 1)
        }
    }

    // MARK: Samples

    static func makeSamples(in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hues: [Double] = [0.58, 0.08, 0.72, 0.33, 0.9, 0.12, 0.5, 0.0, 0.25, 0.62, 0.8, 0.15]
        for (i, h) in hues.enumerated() {
            let url = dir.appendingPathComponent(String(format: "sample-%02d.jpg", i + 1))
            if let img = scene(width: 3000, height: 2000, hue: h, variant: i) { write(img, to: url) }
        }
        print("Wrote \(hues.count) samples to \(dir.path)")
    }

    /// Sky gradient, sun, hills, a gray ramp and a row of color patches.
    static func scene(width: Int, height: Int, hue: Double, variant: Int) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(width), H = CGFloat(height)
        func rgb(_ h: Double, _ s: Double, _ b: Double) -> CGColor {
            let c = NSColorShim.hsb(h, s, b)
            return CGColor(colorSpace: cs, components: [c.0, c.1, c.2, 1])!
        }
        // Sky (CG origin bottom-left)
        let sky = CGGradient(colorsSpace: cs, colors: [rgb(hue, 0.15, 0.95), rgb(hue, 0.55, 0.75)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H * 0.45), end: CGPoint(x: 0, y: H), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
        // Sun
        ctx.setFillColor(rgb(0.13, 0.25, 1))
        ctx.fillEllipse(in: CGRect(x: W * (0.6 + Double(variant % 3) * 0.1), y: H * 0.72, width: W * 0.08, height: W * 0.08))
        // Hills
        ctx.setFillColor(rgb((hue + 0.45).truncatingRemainder(dividingBy: 1), 0.35, 0.4))
        ctx.beginPath(); ctx.move(to: CGPoint(x: 0, y: H * 0.35))
        for i in 0...12 { ctx.addLine(to: CGPoint(x: W * CGFloat(i) / 12, y: H * (0.4 + 0.12 * sin(Double(i + variant) * 1.3)))) }
        ctx.addLine(to: CGPoint(x: W, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: 0)); ctx.fillPath()
        ctx.setFillColor(rgb(0.3, 0.45, 0.25))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H * 0.3))
        // Gray ramp (bottom strip, 10 steps)
        for i in 0..<10 {
            let g = CGFloat(i) / 9
            ctx.setFillColor(CGColor(colorSpace: cs, components: [g, g, g, 1])!)
            ctx.fill(CGRect(x: W * CGFloat(i) / 10, y: 0, width: W / 10, height: H * 0.1))
        }
        // Color patches (8 hues)
        for i in 0..<8 {
            let hh = [0.0, 30, 60, 120, 180, 225, 270, 315][i] / 360
            ctx.setFillColor(rgb(hh, 0.8, 0.8))
            ctx.fill(CGRect(x: W * CGFloat(i) / 8 + 10, y: H * 0.12, width: W / 8 - 20, height: H * 0.12))
        }
        return ctx.makeImage()
    }

    static func write(_ img: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    // MARK: Checks

    struct RGB: CustomStringConvertible {
        var r: Double, g: Double, b: Double
        var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        var sat: Double { max(r, g, b) - min(r, g, b) }
        var description: String { String(format: "(%.3f %.3f %.3f)", r, g, b) }
    }

    /// Average color in a small box around a normalized (top-left) point of the rendered output.
    static func sample(_ image: CIImage, _ x: Double, _ y: Double) -> RGB {
        let e = image.extent
        let px = e.minX + x * e.width, py = e.minY + (1 - y) * e.height
        let box = CGRect(x: px - 4, y: py - 4, width: 8, height: 8)
        let avg = image.cropped(to: box).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: box)])
        var p = [Float](repeating: 0, count: 4)
        Render.background.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 format: .RGBAf, colorSpace: Render.sRGB)
        return RGB(r: Double(p[0]), g: Double(p[1]), b: Double(p[2]))
    }

    /// Sorted sRGB-encoded luminance of every pixel: the reference the histogram is checked against.
    static func sortedLuminances(_ image: CIImage) -> [Double] {
        let e = image.extent.integral
        let w = Int(e.width), h = Int(e.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        Render.background.render(image, toBitmap: &px, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: Render.sRGB)
        var out = [Double]()
        out.reserveCapacity(w * h)
        for i in stride(from: 0, to: px.count, by: 4) {
            out.append((0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255)
        }
        return out.sorted()
    }

    /// Spread of the middle 90% of luminances: a stand-in for overall contrast.
    static func spread(_ image: CIImage) -> Double {
        let l = sortedLuminances(image)
        return l[l.count * 95 / 100] - l[l.count * 5 / 100]
    }

    /// Standard deviation of luminance in a 24-pixel box around a normalized point.
    static func noise(_ image: CIImage, _ x: Double, _ y: Double) -> Double {
        let e = image.extent
        let box = CGRect(x: e.minX + x * e.width - 12, y: e.minY + (1 - y) * e.height - 12, width: 24, height: 24).integral
        var px = [Float](repeating: 0, count: 24 * 24 * 4)
        Render.background.render(image, toBitmap: &px, rowBytes: 24 * 16, bounds: box, format: .RGBAf, colorSpace: Render.sRGB)
        var l: [Double] = []
        for i in stride(from: 0, to: px.count, by: 4) {
            let y: Float = 0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2]
            l.append(Double(y))
        }
        let mean = l.reduce(0, +) / Double(l.count)
        var sum = 0.0
        for v in l { sum += (v - mean) * (v - mean) }
        return (sum / Double(l.count)).squareRoot()
    }

    /// Curves, presence, grain, lens, ranges and spot removal.
    static func newToolChecks(src: ImageSource, base: CIImage, check: (String, Bool, String) -> Void) {
        let gray = (0.55, 0.95), dark = (0.15, 0.95), skyP = (0.3, 0.1), bluePatch = (5.5 / 8, 0.82), corner = (0.02, 0.02)
        func s(_ i: CIImage, _ p: (Double, Double)) -> RGB { sample(i, p.0, p.1) }
        let lift = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)]

        var a = Adjustments(); a.curveRed = lift
        let red = s(src.developed(a), gray), g0 = s(base, gray)
        check("red curve warms only red", red.r > g0.r + 0.05 && abs(red.g - g0.g) < 0.01 && abs(red.b - g0.b) < 0.01, "\(g0) -> \(red)")

        a = Adjustments(); a.parametric.shadows = 80
        check("parametric shadows lifts dark tones", s(src.developed(a), dark).luma > s(base, dark).luma + 0.02, "\(s(base, dark)) -> \(s(src.developed(a), dark))")
        var extreme = ParametricCurve(); extreme.shadows = -100; extreme.darks = 100; extreme.lights = -100; extreme.highlights = 100
        let shape = ParametricShape(extreme)!
        let samples = (0...100).map { shape.evaluate(Double($0) / 100) }
        check("parametric curve never folds back", zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } && samples.first! == 0, "")

        a = Adjustments(); HueCurves.setPoint(&a.hueCurves.saturation, x: 220.0 / 360, y: 0)
        check("hue curve point gets neutral anchors", a.hueCurves.saturation.count == 3, "\(a.hueCurves.saturation)")
        let bp = s(base, bluePatch), desat = s(src.developed(a), bluePatch)
        check("hue vs saturation desaturates blue", desat.sat < bp.sat * 0.5, "\(bp) -> \(desat)")
        let flatAway = PeriodicCurve(points: a.hueCurves.saturation)
        check("hue curve stays neutral away from its points", (0..<100).allSatisfy { i in
            let x = Double(i) / 100
            return (x > 0.52 && x < 0.70) || abs(flatAway.evaluate(x) - 0.5) < 1e-9
        }, "")
        check("hue vs saturation leaves gray alone", abs(s(src.developed(a), gray).luma - g0.luma) < 0.01, "")
        let pc = PeriodicCurve(points: [CurvePoint(x: 0.02, y: 0.9), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 0.95, y: 0.2)])
        check("hue curve wraps around smoothly", abs(pc.evaluate(0) - pc.evaluate(0.99999)) < 0.01, "\(pc.evaluate(0)) vs \(pc.evaluate(0.99999))")
        a = Adjustments(); HueCurves.setPoint(&a.hueCurves.hue, x: 220.0 / 360, y: 1)
        let shifted = s(src.developed(a), bluePatch)
        check("hue vs hue shifts blue", abs(shifted.r - bp.r) + abs(shifted.g - bp.g) > 0.05, "\(bp) -> \(shifted)")

        let baseSpread = spread(base)
        a = Adjustments(); a.clarity = 100
        check("clarity + adds contrast", spread(src.developed(a)) > baseSpread + 0.005, "\(baseSpread) -> \(spread(src.developed(a)))")
        a = Adjustments(); a.texture = 100
        check("texture + brings out fine detail", noise(src.developed(a), 0.3, 0.6) > noise(base, 0.3, 0.6) * 1.3,
              "\(noise(base, 0.3, 0.6)) -> \(noise(src.developed(a), 0.3, 0.6))")
        a = Adjustments(); a.dehaze = 80
        let hazeOut = src.developed(a)
        check("dehaze + deepens veiled midtones and brings back color",
              s(hazeOut, gray).luma < g0.luma - 0.03 && s(hazeOut, skyP).sat > s(base, skyP).sat + 0.05,
              "gray \(g0) -> \(s(hazeOut, gray)); sky \(s(base, skyP)) -> \(s(hazeOut, skyP))")
        // Next to bright sky, a dark edge must not be pushed to black (the haze estimate is blurred).
        let edgeImage = CIImage(color: CIColor(red: 0.8, green: 0.85, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let darkHalf = CIImage(color: CIColor(red: 0.08, green: 0.06, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
        let scene = darkHalf.composited(over: edgeImage)
        let dehazed = Effects.dehaze(scene, amount: 80, longEdge: 600)
        check("dehaze leaves no dark band along bright edges",
              sample(dehazed, 0.48, 0.5).luma > sample(dehazed, 0.2, 0.5).luma * 0.85,
              "near edge \(sample(dehazed, 0.48, 0.5)), inside \(sample(dehazed, 0.2, 0.5))")
        a = Adjustments(); a.dehaze = -80
        check("dehaze - flattens", spread(src.developed(a)) < baseSpread - 0.02, "\(baseSpread) -> \(spread(src.developed(a)))")

        a = Adjustments(); a.grain.amount = 80
        let grained = src.developed(a)
        check("grain adds noise to flat areas", noise(grained, 0.3, 0.1) > noise(base, 0.3, 0.1) + 0.01, "\(noise(base, 0.3, 0.1)) -> \(noise(grained, 0.3, 0.1))")
        check("grain keeps the average", abs(s(grained, gray).luma - g0.luma) < 0.03, "\(g0) -> \(s(grained, gray))")
        check("grain is the same every render", abs(noise(src.developed(a), 0.3, 0.1) - noise(grained, 0.3, 0.1)) < 1e-6, "")

        a = Adjustments(); a.lens.vignetting = 80
        check("lens vignetting + brightens corners", s(src.developed(a), corner).luma > s(base, corner).luma + 0.02, "\(s(base, corner)) -> \(s(src.developed(a), corner))")
        a = Adjustments(); a.lens.distortion = 60
        check("distortion correction moves pixels", abs(s(src.developed(a), (0.5, 0.25)).luma - s(base, (0.5, 0.25)).luma) > 0.002 || abs(s(src.developed(a), (0.25, 0.5)).b - s(base, (0.25, 0.5)).b) > 0.002, "")
        a = Adjustments(); a.lens.removeFringing = true
        check("fringe removal leaves flat areas alone", abs(s(src.developed(a), gray).luma - g0.luma) < 0.01 && abs(s(src.developed(a), bluePatch).sat - bp.sat) < 0.02, "")

        // Ranges: a mask over the whole photo limited by brightness, then by color.
        a = Adjustments()
        var m = Mask(name: "All", kind: .radial)
        m.radiusX = 3; m.radiusY = 3; m.feather = 0; m.local.exposure = 1
        var range = MaskRange(kind: .luminance); range.low = 0.6; range.smoothness = 0.05
        m.range = range
        a.masks = [m]
        let ranged = src.developed(a)
        check("brightness range keeps dark tones out", abs(s(ranged, dark).luma - s(base, dark).luma) < 0.01, "\(s(base, dark)) -> \(s(ranged, dark))")
        check("brightness range lets bright tones in", s(ranged, skyP).luma > s(base, skyP).luma + 0.03, "\(s(base, skyP)) -> \(s(ranged, skyP))")
        var colorRange = MaskRange(kind: .color)
        colorRange.red = bp.r; colorRange.green = bp.g; colorRange.blue = bp.b; colorRange.tolerance = 25
        m.range = colorRange
        a.masks = [m]
        let colored = src.developed(a)
        check("color range changes the picked color", s(colored, bluePatch).luma > bp.luma + 0.03, "\(bp) -> \(s(colored, bluePatch))")
        check("color range leaves other colors", abs(s(colored, gray).luma - g0.luma) < 0.01, "\(g0) -> \(s(colored, gray))")

        // Spot removal on a flat gray frame with a black dot.
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let flat = CIImage(color: CIColor(red: 0.4, green: 0.45, blue: 0.5)).cropped(to: frame)
        let dot = CIImage(color: .black).cropped(to: CGRect(x: 195, y: 145, width: 10, height: 10))
        let dirty = dot.composited(over: flat)
        let spot = Spot(center: NormPoint(x: 0.5, y: 0.5), source: NormPoint(x: 0.7, y: 0.5), radius: 0.03)
        let cleaned = Effects.removeSpots(dirty, [spot])
        let before = sample(dirty, 0.5, 0.5), after = sample(cleaned, 0.5, 0.5), clean = sample(flat, 0.5, 0.5)
        check("spot removal hides the spot", abs(after.luma - clean.luma) < 0.02 && before.luma < clean.luma - 0.1, "\(before) -> \(after) (clean \(clean))")
        check("spot removal leaves the rest", abs(sample(cleaned, 0.2, 0.2).luma - clean.luma) < 0.002, "")

        // Edits survive a save and load, and old files without the new fields still load.
        var all = Adjustments()
        all.curveGreen = lift; all.parametric.lights = 20; all.texture = 10; all.clarity = -5; all.dehaze = 30
        all.grain.amount = 40; all.lens.removeFringing = true; all.lens.distortion = 12
        HueCurves.setPoint(&all.hueCurves.luminance, x: 0.3, y: 0.7)
        all.spots = [spot]
        var rm = Mask(name: "R", kind: .radial); rm.range = colorRange; rm.local.dehaze = 20
        all.masks = [rm]
        let json = try? JSONEncoder().encode(all)
        let back = json.flatMap { try? JSONDecoder().decode(Adjustments.self, from: $0) }
        check("new edits round-trip through JSON", back == all, "")
        let old = try? JSONDecoder().decode(Adjustments.self, from: Data(#"{"exposure": 0.5, "curve": [{"x":0,"y":0},{"x":1,"y":1}]}"#.utf8))
        check("old edits load with new fields neutral", old?.exposure == 0.5 && old?.spots == [] && old?.lens == LensCorrection() && old?.hueCurves == HueCurves(), "")
        check("plain paste leaves spots and crop", !SettingsGroup.standard.contains(.spots) && !SettingsGroup.standard.contains(.crop), "")
    }

    static func run(dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("selftest.jpg")
        guard let img = scene(width: 1500, height: 1000, hue: 0.58, variant: 0) else { return false }
        write(img, to: url)
        guard let src = ImageSource(url: url, maxPixelSize: nil) else { print("FAIL could not load"); return false }

        var ok = true
        func check(_ name: String, _ cond: Bool, _ detail: String) {
            print("\(cond ? "PASS" : "FAIL")  \(name)  \(detail)")
            if !cond { ok = false }
        }
        let base = src.developed(Adjustments())
        // Points: mid-gray ramp step, sky, a dark ramp step, blue patch, corner.
        let gray = (0.55, 0.95), dark = (0.15, 0.95), skyP = (0.3, 0.1), bluePatch = (5.5 / 8, 0.82), corner = (0.02, 0.02)
        func s(_ i: CIImage, _ p: (Double, Double)) -> RGB { sample(i, p.0, p.1) }

        var a = Adjustments(); a.exposure = 1
        check("exposure +1 brightens", s(src.developed(a), gray).luma > s(base, gray).luma + 0.1, "\(s(base, gray)) -> \(s(src.developed(a), gray))")

        a = Adjustments(); a.temperature = 60
        let warm = s(src.developed(a), gray)
        check("temperature + warms", warm.r - warm.b > 0.03, "\(warm)")
        a = Adjustments(); a.tint = 60
        let tint = s(src.developed(a), gray)
        check("tint + is magenta", (tint.r + tint.b) / 2 - tint.g > 0.02, "\(tint)")

        a = Adjustments(); a.contrast = 80
        check("contrast + darkens darks", s(src.developed(a), dark).luma < s(base, dark).luma - 0.02, "\(s(base, dark)) -> \(s(src.developed(a), dark))")

        a = Adjustments(); a.vignette = -80
        check("vignette - darkens corners", s(src.developed(a), corner).luma < s(base, corner).luma - 0.05, "\(s(base, corner)) -> \(s(src.developed(a), corner))")

        a = Adjustments(); a.hsl[HSLColor.blue.rawValue].saturation = -100
        check("HSL blue sat -100 desaturates blue", s(src.developed(a), bluePatch).sat < s(base, bluePatch).sat * 0.5, "\(s(base, bluePatch)) -> \(s(src.developed(a), bluePatch))")

        a = Adjustments(); a.grading.shadows = GradeWheel(hue: 220, saturation: 80)
        let graded = s(src.developed(a), dark)
        check("shadow wheel tints darks blue", graded.b - graded.r > 0.03, "\(s(base, dark)) -> \(graded)")
        check("shadow wheel leaves sky mostly alone", abs(s(src.developed(a), skyP).b - s(base, skyP).b) < 0.06, "")

        a = Adjustments(); a.curve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)]
        check("curve lifts mids", s(src.developed(a), gray).luma > s(base, gray).luma + 0.05, "")

        newToolChecks(src: src, base: base, check: check)

        a = Adjustments()
        var m = Mask(name: "Radial", kind: .radial)
        m.center = NormPoint(x: 0.3, y: 0.1); m.radiusX = 0.1; m.radiusY = 0.1; m.local.exposure = 1.5
        a.masks = [m]
        let masked = src.developed(a)
        check("radial mask brightens inside", s(masked, skyP).luma > s(base, skyP).luma + 0.03, "\(s(base, skyP)) -> \(s(masked, skyP))")
        check("radial mask leaves outside alone", abs(s(masked, gray).luma - s(base, gray).luma) < 0.01, "")

        var lin = Mask(name: "Linear", kind: .linear)
        lin.start = NormPoint(x: 0.5, y: 0); lin.end = NormPoint(x: 0.5, y: 0.4); lin.local.exposure = -1.5
        a.masks = [lin]
        let gradOut = src.developed(a)
        check("linear mask darkens top", s(gradOut, skyP).luma < s(base, skyP).luma - 0.05, "")
        check("linear mask leaves bottom", abs(s(gradOut, gray).luma - s(base, gray).luma) < 0.01, "")

        var brush = Mask(name: "Brush", kind: .brush)
        brush.strokes = [BrushStroke(points: [NormPoint(x: 0.5, y: 0.95), NormPoint(x: 0.6, y: 0.95)], radius: 0.05, feather: 0.3)]
        brush.local.exposure = 1.5
        a.masks = [brush]
        check("brush mask brightens painted area", s(src.developed(a), gray).luma > s(base, gray).luma + 0.05, "")

        var sky = Mask(name: "Sky", kind: .sky); sky.local.exposure = -1
        a.masks = [sky]
        let skyOut = src.developed(a)
        check("sky mask darkens sky", s(skyOut, skyP).luma < s(base, skyP).luma - 0.05, "\(s(base, skyP)) -> \(s(skyOut, skyP))")
        check("sky mask spares ground", abs(s(skyOut, gray).luma - s(base, gray).luma) < 0.03, "")

        a = Adjustments(); a.crop.rect = NormRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cropped = src.developed(a)
        check("crop halves size", abs(cropped.extent.width - 750) < 2 && abs(cropped.extent.height - 500) < 2, "\(cropped.extent.size)")
        a.crop.angle = 10
        let rotated = src.developed(a)
        check("straighten keeps a filled frame", sample(rotated, 0.01, 0.01).luma > 0.05, "\(rotated.extent.size)")

        // Export round trip.
        var exp = Adjustments(); exp.exposure = 0.5; exp.masks = [m]
        var settings = ExportSettings(); settings.longEdge = 800
        do {
            let out = try Exporter.export((url, exp), settings: settings, to: dir)
            let loaded = CIImage(contentsOf: out)
            check("export writes resized JPEG", loaded.map { max($0.extent.width, $0.extent.height) == 800 } ?? false, out.lastPathComponent)
        } catch {
            check("export writes resized JPEG", false, error.localizedDescription)
        }

        // Mask refinement: subtract at the center of a radial, add in a corner.
        let size = CGSize(width: 1500, height: 1000)
        let grayBase = CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size))
        var r = Mask(name: "R", kind: .radial)
        r.radiusX = 0.3; r.radiusY = 0.3
        r.strokes = [BrushStroke(points: [NormPoint(x: 0.5, y: 0.5)], radius: 0.04, feather: 0.2, erase: true),
                     BrushStroke(points: [NormPoint(x: 0.1, y: 0.1)], radius: 0.04, feather: 0.2)]
        if let mi = MaskRenderer.image(for: r, size: size, url: url, base: grayBase) {
            check("refine: subtract clears inside", sample(mi, 0.5, 0.5).g < 0.1, "\(sample(mi, 0.5, 0.5))")
            check("refine: add paints outside", sample(mi, 0.1, 0.1).g > 0.8, "\(sample(mi, 0.1, 0.1))")
            check("refine: untouched area keeps mask", sample(mi, 0.5, 0.38).g > 0.5, "\(sample(mi, 0.5, 0.38))")
        }
        r.invert = true
        if let mi = MaskRenderer.image(for: r, size: size, url: url, base: grayBase) {
            check("refine applies after invert", sample(mi, 0.1, 0.1).g > 0.8 && sample(mi, 0.5, 0.5).g < 0.1,
                  "\(sample(mi, 0.1, 0.1)) \(sample(mi, 0.5, 0.5))")
        }

        // Several gradients in one mask: top fades down, an added one fades up from the bottom.
        var two = Mask(name: "L", kind: .linear)
        two.start = NormPoint(x: 0.5, y: 0); two.end = NormPoint(x: 0.5, y: 0.3)
        two.shapes = [MaskShape(kind: .linear, start: NormPoint(x: 0.5, y: 1), end: NormPoint(x: 0.5, y: 0.7))]
        if let mi = MaskRenderer.image(for: two, size: size, url: url, base: grayBase) {
            check("two linears: top masked", sample(mi, 0.5, 0.03).g > 0.8, "\(sample(mi, 0.5, 0.03))")
            check("two linears: bottom masked", sample(mi, 0.5, 0.97).g > 0.8, "\(sample(mi, 0.5, 0.97))")
            check("two linears: middle clear", sample(mi, 0.5, 0.5).g < 0.05, "\(sample(mi, 0.5, 0.5))")
        }
        two.shapes.append(MaskShape(kind: .radial, mode: .subtract, center: NormPoint(x: 0.2, y: 0.03), radiusX: 0.05, radiusY: 0.08, feather: 0.1))
        if let mi = MaskRenderer.image(for: two, size: size, url: url, base: grayBase) {
            check("subtract shape cuts a hole", sample(mi, 0.2, 0.03).g < 0.1 && sample(mi, 0.6, 0.03).g > 0.8,
                  "\(sample(mi, 0.2, 0.03)) \(sample(mi, 0.6, 0.03))")
        }
        var inter = Mask(name: "R", kind: .radial)
        inter.radiusX = 0.4; inter.radiusY = 0.4; inter.feather = 0.1
        inter.shapes = [MaskShape(kind: .linear, mode: .intersect, start: NormPoint(x: 0, y: 0.5), end: NormPoint(x: 0.1, y: 0.5))]
        if let mi = MaskRenderer.image(for: inter, size: size, url: url, base: grayBase) {
            check("intersect keeps only the overlap", sample(mi, 0.3, 0.5).g < 0.05 && sample(mi, 0.03, 0.5).g < 0.05,
                  "\(sample(mi, 0.3, 0.5)) \(sample(mi, 0.03, 0.5))")
        }
        inter.shapes[0].start = NormPoint(x: 0.3, y: 0.5); inter.shapes[0].end = NormPoint(x: 0.6, y: 0.5)
        if let mi = MaskRenderer.image(for: inter, size: size, url: url, base: grayBase) {
            check("intersect passes where both cover", sample(mi, 0.32, 0.5).g > 0.8, "\(sample(mi, 0.32, 0.5))")
        }
        let legacy = #"{"id":"6C1E0F6A-1A44-4B11-9A55-9E1C2B7E9D10","name":"Old","kind":"linear","local":{"exposure":0.5}}"#
        let decoded = try? JSONDecoder().decode(Mask.self, from: Data(legacy.utf8))
        check("older masks still load", decoded?.shapes.isEmpty == true && decoded?.local.exposure == 0.5, "")

        // Subject subsets, picking and grow, using a synthetic detection (left box = 1, right box = 2).
        let fakeURL = dir.appendingPathComponent("fake-subjects.jpg")
        func box(_ rect: CGRect) -> CGImage {
            let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: MaskRenderer.linearGray, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(rect)
            return ctx.makeImage()!
        }
        let left = box(CGRect(x: 60, y: 100, width: 160, height: 200)), right = box(CGRect(x: 380, y: 100, width: 160, height: 200))
        let both = box(CGRect(x: 0, y: 0, width: 0, height: 0))
        let allCtx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                               space: MaskRenderer.linearGray, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        allCtx.draw(both, in: CGRect(x: 0, y: 0, width: 600, height: 400))
        allCtx.setFillColor(gray: 1, alpha: 1)
        allCtx.fill(CGRect(x: 60, y: 100, width: 160, height: 200)); allCtx.fill(CGRect(x: 380, y: 100, width: 160, height: 200))
        let lookup = [left, right].map { SubjectDetector.downsample($0, width: 256, height: 171) }
        SubjectDetector.shared.install(.init(all: allCtx.makeImage()!, instances: [left, right], lookup: lookup, lookupSize: (256, 171)), for: fakeURL)
        var subj = Mask(name: "S", kind: .subject)
        subj.subjects = [1]
        if let mi = MaskRenderer.image(for: subj, size: size, url: fakeURL, base: grayBase, canDetect: false) {
            check("subject subset keeps chosen subject", sample(mi, 140.0 / 600, 0.5).g > 0.8, "\(sample(mi, 140.0 / 600, 0.5))")
            check("subject subset drops the other", sample(mi, 460.0 / 600, 0.5).g < 0.1, "\(sample(mi, 460.0 / 600, 0.5))")
        }
        check("click finds the right subject", SubjectDetector.shared.subject(at: NormPoint(x: 460.0 / 600, y: 0.5), url: fakeURL) == 2
              && SubjectDetector.shared.subject(at: NormPoint(x: 0.5, y: 0.5), url: fakeURL) == nil, "")
        subj.subjects = nil
        // Box edge at x = 60/600; grow ±100 moves it 30 px at 1500 wide (= 12 px at 600).
        subj.grow = 100
        if let mi = MaskRenderer.image(for: subj, size: size, url: fakeURL, base: grayBase, canDetect: false) {
            check("grow expands the edge", sample(mi, 53.0 / 600, 0.5).g > 0.8, "\(sample(mi, 53.0 / 600, 0.5))")
        }
        subj.grow = -100
        if let mi = MaskRenderer.image(for: subj, size: size, url: fakeURL, base: grayBase, canDetect: false) {
            check("shrink pulls the edge in", sample(mi, 67.0 / 600, 0.5).g < 0.2, "\(sample(mi, 67.0 / 600, 0.5))")
        }

        // Real Vision run on an off-center subject: the mask must land on it.
        let visionURL = dir.appendingPathComponent("vision-subject.jpg")
        if let ctx = CGContext(data: nil, width: 1500, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: Render.sRGB,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(srgbRed: 0.82, green: 0.8, blue: 0.76, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1500, height: 1000))
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.15, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 1050, y: 300, width: 330, height: 330))   // center ≈ (0.81, 0.53) top-left coords
            if let img = ctx.makeImage() { write(img, to: visionURL) }
        }
        if let vsrc = ImageSource(url: visionURL, maxPixelSize: nil) {
            var vm = Adjustments(); var sm = Mask(name: "S", kind: .subject); sm.local.exposure = 1
            vm.masks = [sm]
            _ = vsrc.developed(vm, exporting: true)
            if let n = SubjectDetector.shared.subjectCount(visionURL), n > 0,
               let mi = MaskRenderer.image(for: sm, size: vsrc.size, url: visionURL, base: vsrc.developed(Adjustments()), canDetect: false) {
                let on = sample(mi, 1215.0 / 1500, 1 - 465.0 / 1000), off = sample(mi, 0.2, 0.5)
                check("vision mask lands on off-center subject", on.g > 0.5 && off.g < 0.2, "on \(on) off \(off)")
            } else {
                print("SKIP  vision found no subject in the synthetic image")
            }
        }

        // Live brush strokes: painting point by point must give the same pixels as painting at once.
        func bytes(_ img: CGImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: img.width * img.height)
            out.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                ctx?.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            }
            return out
        }
        let wave = (0..<80).map { NormPoint(x: 0.1 + Double($0) * 0.01, y: 0.5 + 0.2 * sin(Double($0) * 0.15)) }
        let strokesFull = [BrushStroke(points: wave, radius: 0.05, feather: 0.6, flow: 0.7),
                           BrushStroke(points: wave.map { NormPoint(x: $0.x, y: $0.y - 0.05) }, radius: 0.02, feather: 0.2, flow: 1, erase: true)]
        let liveID = UUID()
        var liveImage = LiveRaster.rebuild(maskID: liveID, width: 600, height: 400, background: nil, baseKey: nil,
                                           strokes: [BrushStroke(points: Array(wave.prefix(1)), radius: 0.05, feather: 0.6, flow: 0.7)])
        var extendedEveryTime = true
        for count in 2...wave.count {
            let partial = [BrushStroke(points: Array(wave.prefix(count)), radius: 0.05, feather: 0.6, flow: 0.7)]
            liveImage = LiveRaster.extend(maskID: liveID, width: 600, height: 400, baseKey: nil, strokes: partial)
            if liveImage == nil { extendedEveryTime = false; break }
        }
        for count in 1...wave.count where extendedEveryTime {
            var two = strokesFull
            two[1].points = Array(strokesFull[1].points.prefix(count))
            liveImage = LiveRaster.extend(maskID: liveID, width: 600, height: 400, baseKey: nil, strokes: two)
            if liveImage == nil { extendedEveryTime = false }
        }
        check("live strokes extend point by point", extendedEveryTime, "")
        if let live = liveImage, let full = MaskRenderer.rasterize(strokesFull, width: 600, height: 400) {
            let a = bytes(live), b = bytes(full)
            let maxDiff = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 255
            check("live strokes match painting at once", maxDiff <= 1, "max diff \(maxDiff)")
        }
        check("undoing a stroke repaints from scratch",
              LiveRaster.extend(maskID: liveID, width: 600, height: 400, baseKey: nil, strokes: [strokesFull[0]]) == nil, "")

        // Hostile strokes: rendering cost stays bounded by the raster, whatever the stroke says.
        func seconds(_ body: () -> Void) -> Double { let t = Date(); body(); return Date().timeIntervalSince(t) }
        let farStroke = BrushStroke(points: [NormPoint(x: 0, y: 0), NormPoint(x: 1e8, y: 0)], radius: 0, feather: 0.6, flow: 1)
        var farImage: CGImage?
        let farTime = seconds { farImage = MaskRenderer.rasterize([farStroke], width: 1024, height: 683) }
        check("a stroke 1e8 widths long renders quickly", farTime < 1 && farImage != nil, String(format: "%.2fs", farTime))
        let zigzag = BrushStroke(points: (0..<50_000).map { NormPoint(x: $0 % 2 == 0 ? -0.2 : 1.2, y: Double($0 % 97) / 97) }, radius: 0.0005)
        let zigzagTime = seconds { _ = MaskRenderer.rasterize([zigzag], width: 1024, height: 683) }
        check("a 50,000-point zigzag stroke renders in bounded time", zigzagTime < 3, String(format: "%.2fs", zigzagTime))
        // A stroke from far off the image still paints where it crosses it, like a short one does.
        let across = MaskRenderer.rasterize([BrushStroke(points: [NormPoint(x: -40, y: 0.5), NormPoint(x: 40, y: 0.5)], radius: 0.05)], width: 600, height: 400)
        let short = MaskRenderer.rasterize([BrushStroke(points: [NormPoint(x: -0.5, y: 0.5), NormPoint(x: 1.5, y: 0.5)], radius: 0.05)], width: 600, height: 400)
        if let across, let short {
            let a = bytes(across), b = bytes(short)
            let row = 200 * 600
            check("off-image stroke still paints across the image", a[row + 10] > 250 && a[row + 300] > 250 && a[row + 590] > 250
                  && a[20 * 600 + 300] == 0 && b[row + 300] > 250, "\(a[row + 10]) \(a[row + 300]) \(a[row + 590])")
        }
        var badCrop = CropSettings(); badCrop.rect = NormRect(x: 0.5, y: 0.5, width: -1, height: 0)
        let badCropped = ImageSource.applyGeometry(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400)), crop: badCrop, mode: .full)
        check("a degenerate crop renders the full frame", !badCropped.extent.isEmpty && !badCropped.extent.isInfinite, "\(badCropped.extent)")

        // Preview develops at screen resolution: same look at a lower scale.
        var scaledA = Adjustments(); scaledA.highlights = -50; scaledA.shadows = 40; scaledA.hsl[5].saturation = 50; scaledA.vignette = -30
        let fullDev = src.developed(scaledA), halfDev = src.developed(scaledA, renderScale: 0.5)
        check("render scale halves the size", Int(halfDev.extent.width) == Int(fullDev.extent.width) / 2, "\(halfDev.extent.size)")
        let scaleDiffs = [gray, dark, skyP, bluePatch].map { abs(s(fullDev, $0).luma - s(halfDev, $0).luma) }
        check("render scale keeps the look", scaleDiffs.max()! < 0.03, "\(scaleDiffs)")
        let laptop = PreviewRenderer.renderScale(source: ImageSource(image: img, url: url), Adjustments(), geometry: .full,
                                                 drawableSize: CGSize(width: 1000, height: 700), scale: 2)
        let big = PreviewRenderer.renderScale(source: ImageSource(image: img, url: url), Adjustments(), geometry: .full,
                                              drawableSize: CGSize(width: 5000, height: 3000), scale: 2)
        check("render scale fits the drawable", laptop > 0.55 && laptop < 0.75 && big == 1, "\(laptop) / \(big)")
        let zoomedScale = PreviewRenderer.renderScale(source: ImageSource(image: img, url: url), Adjustments(), geometry: .full,
                                                      drawableSize: CGSize(width: 1000, height: 700), scale: 2, zoom: 4)
        check("zoomed in, the preview renders more of the photo's pixels", zoomedScale == 1, "\(zoomedScale)")

        // Editor zoom: the maths.
        let zContent = CGSize(width: 3000, height: 2000), zView = CGSize(width: 1000, height: 700)
        let zFit = PreviewLayout.fit(zContent, in: zView)
        var zoom = PreviewZoom()
        check("zoom starts at fit", zoom.rect(content: zContent, in: zView) == zFit && !zoom.isZoomed, "")
        let anchor = CGPoint(x: 300, y: 250)
        let zBefore = zoom.rect(content: zContent, in: zView)
        let pointBefore = CGPoint(x: (anchor.x - zBefore.minX) / zBefore.width, y: (anchor.y - zBefore.minY) / zBefore.height)
        zoom.zoom(by: 3, anchor: anchor, content: zContent, in: zView, maxScale: 8)
        let zAfter = zoom.rect(content: zContent, in: zView)
        let pointAfter = CGPoint(x: (anchor.x - zAfter.minX) / zAfter.width, y: (anchor.y - zAfter.minY) / zAfter.height)
        check("zooming keeps the point under the pointer still", abs(zoom.scale - 3) < 1e-9
              && abs(pointAfter.x - pointBefore.x) < 1e-6 && abs(pointAfter.y - pointBefore.y) < 1e-6, "\(pointBefore) → \(pointAfter)")
        zoom.pan(by: CGSize(width: 100_000, height: 100_000), content: zContent, in: zView)
        let zPanned = zoom.rect(content: zContent, in: zView)
        check("panning stops at the photo's edges", abs(zPanned.minX) < 1e-6 && abs(zPanned.minY) < 1e-6, "\(zPanned)")
        zoom.pan(by: CGSize(width: -100_000, height: -100_000), content: zContent, in: zView)
        let zPannedBack = zoom.rect(content: zContent, in: zView)
        check("… on every side", abs(zPannedBack.maxX - zView.width) < 1e-6 && abs(zPannedBack.maxY - zView.height) < 1e-6, "\(zPannedBack)")
        zoom.zoom(by: 100, anchor: anchor, content: zContent, in: zView, maxScale: 8)
        check("zooming in stops at the most", zoom.scale == 8, "\(zoom.scale)")
        zoom.zoom(by: 0.0001, anchor: anchor, content: zContent, in: zView, maxScale: 8)
        check("zooming out stops at fit", !zoom.isZoomed && zoom.rect(content: zContent, in: zView) == zFit, "\(zoom)")
        zoom.toggle(to: 4, anchor: CGPoint(x: zFit.minX + zFit.width * 0.3, y: zFit.midY), content: zContent, in: zView)
        check("double-click zooms to 100% on the point clicked", zoom.scale == 4 && abs(zoom.focus.x - 0.3) < 0.01
              && abs(zoom.focus.y - 0.5) < 0.01, "\(zoom)")
        zoom.toggle(to: 4, anchor: nil, content: zContent, in: zView)
        check("double-click again goes back to fit", !zoom.isZoomed && zoom.focus == CGPoint(x: 0.5, y: 0.5), "\(zoom)")

        // Editor zoom: the frame is drawn where the zoom says. 4× on the left of a dark-to-light ramp
        // fills the view with its darkest quarter.
        let zoomTexDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1200, height: 400, mipmapped: false)
        zoomTexDesc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        zoomTexDesc.storageMode = .shared
        func grayRamp() -> CIImage {
            let ctx = CGContext(data: nil, width: 1024, height: 128, bitsPerComponent: 8, bytesPerRow: 0, space: Render.sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for x in 0..<1024 {
                let v = CGFloat(x) / 1023
                ctx.setFillColor(CGColor(colorSpace: Render.sRGB, components: [v, v, v, 1])!)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: 128))
            }
            return CIImage(cgImage: ctx.makeImage()!)
        }
        if let tex = Render.device.makeTexture(descriptor: zoomTexDesc), let cb = Render.commandQueue.makeCommandBuffer() {
            var drawn = PreviewZoom(); drawn.scale = 4; drawn.focus = CGPoint(x: 0.125, y: 0.5)
            PreviewMTKView.encode(grayRamp(), drawableSize: CGSize(width: 1200, height: 400), scale: 1, background: CIColor(red: 1, green: 0, blue: 0),
                                  colorSpace: Render.sRGB, pixelFormat: .bgra8Unorm, commandBuffer: cb, texture: { tex },
                                  placement: { c, v in drawn.rect(content: c, in: v) })
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 1200 * 400 * 4)
            tex.getBytes(&px, bytesPerRow: 1200 * 4, from: MTLRegionMake2D(0, 0, 1200, 400), mipmapLevel: 0)
            func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
                let i = (y * 1200 + x) * 4
                return (Int(px[i + 2]), Int(px[i + 1]), Int(px[i]))
            }
            let corners = [at(0, 0), at(1199, 0), at(0, 399), at(1199, 399)]
            let left = at(2, 200), right = at(1197, 200)
            check("zoomed in, the photo fills the view", corners.allSatisfy { abs($0.r - $0.b) < 6 }, "\(corners)")
            check("zoomed in, it shows the part asked for", left.r < 12 && right.r > 50 && right.r < 85, "\(left) … \(right)")
        }

        // Histogram from the drawn frame: a gray ramp (evenly spread sRGB values) must read back flat.
        let rampCtx = CGContext(data: nil, width: 1024, height: 128, bitsPerComponent: 8, bytesPerRow: 0, space: Render.sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<1024 {
            let v = CGFloat(x) / 1023
            rampCtx.setFillColor(CGColor(colorSpace: Render.sRGB, components: [v, v, v, 1])!)
            rampCtx.fill(CGRect(x: x, y: 0, width: 1, height: 128))
        }
        let ramp = CIImage(cgImage: rampCtx.makeImage()!)
        let histTexDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1200, height: 400, mipmapped: false)
        histTexDesc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        histTexDesc.storageMode = .private
        if let tex = Render.device.makeTexture(descriptor: histTexDesc), let cb = Render.commandQueue.makeCommandBuffer() {
            let rect = PreviewMTKView.encode(ramp, drawableSize: CGSize(width: 1200, height: 400), scale: 1, background: CIColor(red: 1, green: 0, blue: 0),
                                             colorSpace: Render.sRGB, pixelFormat: .bgra8Unorm, commandBuffer: cb, texture: { tex })
            let readback = rect.flatMap { HistogramReadback(source: tex, rect: $0, commandBuffer: cb) }
            cb.commit(); cb.waitUntilCompleted()
            if let h = readback?.read() {
                // Kolmogorov–Smirnov distance from a flat distribution, worst channel.
                func ks(_ x: [Float]) -> Float {
                    let total = max(x.reduce(0, +), 1e-6)
                    var c: Float = 0, d: Float = 0
                    for i in 0..<x.count { c += x[i] / total; d = max(d, abs(c - Float(i + 1) / Float(x.count))) }
                    return d
                }
                let d = max(ks(h.red), ks(h.green), ks(h.blue))
                check("histogram from the drawn frame is right", d < 0.03, String(format: "KS %.3f", d))
            } else {
                check("histogram from the drawn frame is right", false, "no readback")
            }
        }

        // Clipping overlay: pure white turns red, pure black blue, mid gray stays.
        let clipped = ClippingOverlay.apply(base)
        let cw = s(clipped, (0.95, 0.95)), ck = s(clipped, (0.05, 0.95)), cg = s(clipped, gray), og = s(base, gray)
        check("clipping marks blown highlights red", cw.r > 0.9 && cw.g < 0.3, "\(cw)")
        check("clipping marks crushed shadows blue", ck.b > 0.8 && ck.r < 0.3, "\(ck)")
        check("clipping leaves midtones alone", abs(cg.luma - og.luma) < 0.01, "\(og) -> \(cg)")

        // White balance: a warm-tinted copy; picking a gray ramp step must make it neutral again.
        func variant(_ name: String, _ f: (CIImage) -> CIImage) -> ImageSource? {
            let out = f(CIImage(cgImage: img))
            guard let cg = Render.background.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: Render.sRGB) else { return nil }
            let u = dir.appendingPathComponent(name)
            write(cg, to: u)
            return ImageSource(url: u, maxPixelSize: nil)
        }
        if let warm = variant("warm.jpg", { $0.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.12, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.82, w: 0)]) }) {
            let pick = CGRect(x: 0.53, y: 0.93, width: 0.04, height: 0.04)   // a mid-gray ramp step
            let before = AutoAdjust.average(warm.developed(Adjustments()), region: pick)
            let wb = AutoAdjust.whiteBalance(source: warm, adjustments: Adjustments(), region: pick)
            var fixed = Adjustments(); fixed.temperature = wb.temperature; fixed.tint = wb.tint
            let after = AutoAdjust.average(warm.developed(fixed), region: pick)
            func cast(_ c: (Double, Double, Double)) -> Double { abs(log(c.2 / c.0)) + abs(log(c.1 / (c.0 * c.2).squareRoot())) }
            check("white balance pick neutralizes a warm cast", wb.temperature < 0 && cast(after) < 0.03 && cast(after) < cast(before) / 4,
                  String(format: "temp %.0f tint %.0f, cast %.3f -> %.3f", wb.temperature, wb.tint, cast(before), cast(after)))
        }
        if let dim = variant("dim.jpg", { $0.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.8]) }) {
            let t = AutoAdjust.tone(source: dim, adjustments: Adjustments())
            var a = Adjustments(); a.exposure = t.exposure
            let m = AutoAdjust.measure(dim.developed(a, renderScale: 0.25))?.percentile(0.5) ?? 0
            check("auto tone lifts a dark photo", t.exposure > 0.3 && abs(m - 0.42) < 0.08, String(format: "ev %.2f, median %.2f", t.exposure, m))

            // The histogram's percentiles are the ones sorting every pixel gave.
            var worst = 0.0
            for image in [dim.developed(Adjustments(), renderScale: 0.3), base.cropped(to: CGRect(x: 0, y: 0, width: 700, height: 500))] {
                guard let stats = AutoAdjust.measure(image) else { worst = 1; continue }
                let sorted = sortedLuminances(image)
                for p in [0.0, 0.005, 0.05, 0.25, 0.5, 0.75, 0.95, 0.995, 1] {
                    worst = max(worst, abs(stats.percentile(p) - sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]))
                }
            }
            check("histogram percentiles match sorting within 1/255", worst <= 1.0 / 255, String(format: "worst %.4f", worst))
        }

        // White balance solver: few renders, and the end of the range when there's no root inside.
        do {
            var renders = 0
            let root = AutoAdjust.solveNeutral { x in
                renders += 1
                return SIMD2(0.004 * (x.x - 37) + 0.0006 * (x.y + 12), 0.003 * (x.y + 12) - 0.0005 * (x.x - 37) + 0.00001 * (x.y + 12) * (x.y + 12))
            }
            check("white balance solve converges in few renders", abs(root.x - 37) < 1 && abs(root.y + 12) < 1 && renders <= 6,
                  String(format: "(%.2f, %.2f) after %d renders", root.x, root.y, renders))
            renders = 0
            let pinned = AutoAdjust.solveNeutral { x in renders += 1; return SIMD2(0.004 * (x.x - 160), 0.003 * x.y) }
            check("white balance solve stops at the end of the range", pinned.x > 99 && abs(pinned.y) < 1 && renders <= 12,
                  String(format: "(%.2f, %.2f) after %d renders", pinned.x, pinned.y, renders))
        }

        // The engine measures off its own decode and caches by the inputs that matter.
        do {
            let engine = AutoEngine()
            var a = Adjustments(); a.temperature = 10
            let first = engine.resultNow(for: AutoRequest(url: url, kind: .tone, adjustments: a))
            a.vignette = -30; a.saturation = 20
            let again = engine.resultNow(for: AutoRequest(url: url, kind: .tone, adjustments: a))
            check("auto results are cached across unrelated edits", first != nil && first == again && engine.measurementCount == 1,
                  "\(engine.measurementCount) measurements")
            a.temperature = -20
            _ = engine.resultNow(for: AutoRequest(url: url, kind: .tone, adjustments: a))
            a.crop.rect = NormRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
            _ = engine.resultNow(for: AutoRequest(url: url, kind: .tone, adjustments: a))
            check("auto measures again when its inputs change", engine.measurementCount == 3, "\(engine.measurementCount) measurements")
            let wbA = engine.resultNow(for: AutoRequest(url: url, kind: .whiteBalance, adjustments: Adjustments()))?.whiteBalance
            let wbB = AutoAdjust.whiteBalance(source: src, adjustments: Adjustments(), region: nil)
            check("measurement decode gives the same white balance as full size", wbA.map { abs($0.temperature - wbB.temperature) <= 2 && abs($0.tint - wbB.tint) <= 2 } == true,
                  "\(String(describing: wbA)) vs \(wbB)")
        }

        // Auto: scene-aware choices on synthetic photos with known exposure.
        do {
            func synthetic(_ name: String, _ draw: (CGContext, CGFloat, CGFloat) -> Void) -> ImageSource? {
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                guard let ctx = CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                draw(ctx, 900, 600)
                guard let cg = ctx.makeImage() else { return nil }
                let u = dir.appendingPathComponent(name)
                write(cg, to: u)
                return ImageSource(url: u, maxPixelSize: nil)
            }
            func gray(_ v: Double) -> CGColor { CGColor(colorSpace: Render.sRGB, components: [v, v, v, 1])! }
            func color(_ h: Double, _ sat: Double, _ b: Double) -> CGColor {
                let c = NSColorShim.hsb(h, sat, b)
                return CGColor(colorSpace: Render.sRGB, components: [c.0, c.1, c.2, 1])!
            }
            func ramp(_ ctx: CGContext, _ H: CGFloat, _ from: Double, _ to: Double) {
                let g = CGGradient(colorsSpace: Render.sRGB, colors: [gray(from), gray(to)] as CFArray, locations: [0, 1])!
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: H), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            func describe(_ r: AutoResult) -> String {
                let t = r.tone, l = r.levels, c = r.color, wb = r.whiteBalance
                return String(format: "%@ ev %.2f c %.0f h %.0f s %.0f w %.0f b %.0f vib %.0f sat %.0f wb %.0f/%.0f",
                              r.scene?.rawValue ?? "-", t?.exposure ?? .nan, t?.contrast ?? .nan, t?.highlights ?? .nan, t?.shadows ?? .nan,
                              l?.whites ?? .nan, l?.blacks ?? .nan, c?.vibrance ?? .nan, c?.saturation ?? .nan,
                              wb?.temperature ?? .nan, wb?.tint ?? .nan)
            }

            // Weights line up with the render: the top half of a red-over-blue frame reads red.
            if let split = synthetic("split.jpg", { ctx, W, H in
                ctx.setFillColor(color(0.66, 0.9, 0.8)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H / 2))
                ctx.setFillColor(color(0, 0.9, 0.8)); ctx.fill(CGRect(x: 0, y: H / 2, width: W, height: H / 2))
            }), let bm = AutoAdjust.readback(AutoAdjust.measurementImage(split, Adjustments())) {
                var mask = [UInt8](repeating: 0, count: bm.width * bm.height)
                for i in 0..<(bm.width * bm.height / 2) { mask[i] = 255 }
                let image = AutoAdjust.measurementImage(split, Adjustments())
                let weighted = image.applyingFilter("CIMultiplyCompositing",
                                                    parameters: [kCIInputBackgroundImageKey: AutoAdjust.weightImage(mask, like: bm)]).cropped(to: image.extent)
                let (r, _, b) = AutoAdjust.average(weighted, region: nil)
                check("white balance weights line up with the photo", r > b * 4, String(format: "r %.3f b %.3f", r, b))
            }

                if let fine = synthetic("well-exposed.jpg", { ctx, W, H in
                ramp(ctx, H, 0.03, 0.96)
                for i in 0..<6 {
                    ctx.setFillColor(color(Double(i) / 6, 0.45, 0.7))
                    ctx.fillEllipse(in: CGRect(x: 40 + CGFloat(i) * 140, y: H * 0.4, width: 90, height: 90))
                }
            }) {
                let r = AutoAdjust.auto(source: fine, inputs: Adjustments())
                let t = r.tone!, l = r.levels!, wb = r.whiteBalance!
                let small = [t.contrast, t.highlights, t.shadows, l.whites, l.blacks].allSatisfy { abs($0) <= 10 }
                check("auto leaves a well-exposed photo nearly alone", abs(t.exposure) <= 0.15 && small
                      && abs(wb.temperature) <= 5 && abs(wb.tint) <= 5, describe(r))
            }

            if let lowKey = synthetic("low-key.jpg", { ctx, W, H in
                ramp(ctx, H, 0.02, 0.25)
                ctx.setFillColor(gray(0.9)); ctx.fill(CGRect(x: W * 0.6, y: H * 0.5, width: W * 0.25, height: H * 0.25))
            }) {
                let r = AutoAdjust.auto(source: lowKey, inputs: Adjustments())
                check("auto keeps a low-key photo dark", r.scene == .lowKey && r.tone!.exposure <= 0.6, describe(r))
            }

            if let night = synthetic("night.jpg", { ctx, W, H in
                ramp(ctx, H, 0.02, 0.12)
                ctx.setFillColor(gray(1))
                for i in 0..<24 { ctx.fillEllipse(in: CGRect(x: 30 + CGFloat(i % 12) * 72, y: H * (i < 12 ? 0.3 : 0.6), width: 16, height: 16)) }
            }) {
                let r = AutoAdjust.auto(source: night, inputs: Adjustments())
                let t = r.tone!
                check("auto treats a night scene gently", r.scene == .night && t.highlights == 0 && t.shadows <= 20 && t.exposure <= 0.3
                      && r.levels!.whites == 0, describe(r))
            }

            if let highKey = synthetic("high-key.jpg", { ctx, W, H in
                ramp(ctx, H, 0.72, 0.95)
                ctx.setFillColor(gray(0.1)); ctx.fill(CGRect(x: W * 0.4, y: H * 0.3, width: W * 0.2, height: H * 0.4))
            }) {
                let r = AutoAdjust.auto(source: highKey, inputs: Adjustments())
                check("auto keeps a high-key photo bright", r.scene == .highKey && r.tone!.exposure >= -0.4, describe(r))
            }

            if let flat = synthetic("flat.jpg", { ctx, W, H in
                ramp(ctx, H, 0.3, 0.6)
                for i in 0..<6 {
                    ctx.setFillColor(color(Double(i) / 6, 0.22, 0.55))
                    ctx.fill(CGRect(x: CGFloat(i) * 150, y: H * 0.35, width: 150, height: H * 0.3))
                }
            }) {
                let r = AutoAdjust.auto(source: flat, inputs: Adjustments())
                check("auto stretches a flat, muted photo", r.levels!.whites > 0 && r.levels!.blacks < 0 && r.tone!.contrast > 0
                      && r.color!.vibrance > 5, describe(r))
            }

            // Frames with no detail at all (a lens-cap black, a fully blown white) and tiny ones:
            // auto stays finite and leaves exposure and the tone sliders alone.
            for (name, v) in [("all-black.jpg", 0.0), ("all-white.jpg", 1.0)] {
                if let blank = synthetic(name, { ctx, W, H in ctx.setFillColor(gray(v)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H)) }) {
                    let r = AutoAdjust.auto(source: blank, inputs: Adjustments())
                    let out = StyleSliders.values(r.applied(to: Adjustments()))
                    check("auto leaves a blank \(v == 0 ? "black" : "white") frame alone", out.allSatisfy { $0 == 0 }, describe(r))
                }
            }
            do {
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                if let ctx = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.setFillColor(gray(0.2)); ctx.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
                    let u = dir.appendingPathComponent("tiny.jpg")
                    if let cg = ctx.makeImage() { write(cg, to: u) }
                    let r = ImageSource(url: u, maxPixelSize: nil).map { AutoAdjust.auto(source: $0, inputs: Adjustments()) }
                    let out = r.map { StyleSliders.values($0.applied(to: Adjustments())) } ?? [.nan]
                    check("auto on a 3×2 pixel photo is finite and leaves tone alone", out.allSatisfy(\.isFinite) && r?.tone?.exposure == 0,
                          r.map(describe) ?? "unreadable")
                }
            }

            // The sky-heavy test scene has a neutral gray ramp: auto balances on it rather than the
            // whole-frame average (which warms it a lot).
            let gw = AutoAdjust.whiteBalance(source: src, adjustments: Adjustments(), region: nil)
            let sceneAuto = AutoAdjust.auto(source: src, inputs: Adjustments())
            check("auto white balance trusts the grays over a blue sky", abs(sceneAuto.whiteBalance!.temperature) < abs(gw.temperature) / 2,
                  "auto \(describe(sceneAuto)), whole frame \(gw.temperature)")

            // Vibrance: toward typical colorfulness, careful with skin and faces, never on black and white.
            if let base = sceneAuto.stats {
                var muted = base; muted.meanChroma = 0.02; muted.skinFraction = 0
                var skin = muted; skin.skinFraction = 0.35
                var mono = muted; mono.meanChroma = 0.003; mono.chroma = [mono.pixelCount] + Array(repeating: 0, count: ImageStats.chromaBins - 1)
                let m = AutoAdjust.color(muted), sk = AutoAdjust.color(skin)
                let face = AutoAdjust.color(muted, hints: AutoHints(faces: [CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)]))
                check("vibrance lifts muted color", m.vibrance >= 12 && m.saturation > 0 && m.saturation <= 5, "\(m)")
                check("vibrance holds back on skin", sk.vibrance < m.vibrance && sk.saturation == 0, "\(sk)")
                check("vibrance holds back on faces, saturation never rises", face.vibrance <= min(15, m.vibrance / 2 + 0.5)
                      && face.saturation == 0, "\(face)")
                check("no vibrance on black and white", AutoAdjust.color(mono) == AutoAdjust.ColorBoost(vibrance: 0, saturation: 0), "")
            }

            // Auto starts from defaults, so pressing it again on its own result is a cache hit and no change.
            let engine = AutoEngine()
            let first = engine.resultNow(for: AutoRequest(url: url, kind: .auto, adjustments: Adjustments()))
            let applied = first?.applied(to: Adjustments()) ?? Adjustments()
            let second = engine.resultNow(for: AutoRequest(url: url, kind: .auto, adjustments: applied))
            check("auto twice changes nothing more", first != nil && second?.applied(to: applied) == applied && engine.measurementCount == 1,
                  "\(engine.measurementCount) measurements")

            // Faces (installed through the Vision test hook): exposure leans toward them, skin
            // stays out of green and magenta, and vibrance holds back.
            let faceBox = CGRect(x: 0.4, y: 0.25, width: 0.2, height: 0.3)   // top-left origin
            func portrait(_ name: String, skin: (Double, Double, Double)) -> ImageSource? {
                synthetic(name) { ctx, W, H in
                    ramp(ctx, H, 0.15, 0.95)
                    ctx.setFillColor(CGColor(colorSpace: Render.sRGB, components: [skin.0, skin.1, skin.2, 1])!)
                    // CG's origin is bottom-left.
                    ctx.fill(CGRect(x: faceBox.minX * W, y: (1 - faceBox.maxY) * H, width: faceBox.width * W, height: faceBox.height * H))
                }
            }
            if let dark = portrait("face-dark.jpg", skin: (0.30, 0.20, 0.15)) {
                AutoVision.shared.install(faces: [], for: dark.url)
                let plain = AutoAdjust.auto(source: dark, inputs: Adjustments())
                AutoVision.shared.install(faces: [faceBox], for: dark.url)
                let withFace = AutoAdjust.auto(source: dark, inputs: Adjustments())
                check("a dark face pulls exposure up", withFace.tone!.exposure > plain.tone!.exposure
                      && withFace.tone!.exposure - plain.tone!.exposure <= 0.5 + 1e-9 && withFace.hints.faces == [faceBox],
                      "\(describe(plain)) -> \(describe(withFace))")
                check("faces never raise saturation", withFace.color!.saturation == 0, describe(withFace))
            }
            if let green = portrait("face-green.jpg", skin: (0.62, 0.62, 0.42)), let normal = portrait("face-normal.jpg", skin: (0.88, 0.67, 0.55)) {
                AutoVision.shared.install(faces: [faceBox], for: green.url)
                AutoVision.shared.install(faces: [faceBox], for: normal.url)
                let g = AutoAdjust.auto(source: green, inputs: Adjustments())
                let n = AutoAdjust.auto(source: normal, inputs: Adjustments())
                func faceHue(_ source: ImageSource, _ r: AutoResult) -> Double {
                    let a = r.applied(to: Adjustments())
                    let (cr, cg, cb) = AutoAdjust.average(AutoAdjust.measurementImage(source, a), region: AutoAdjust.faceCore(faceBox))
                    let lab = Oklab(cr, cg, cb)
                    return atan2(lab.b, lab.a) * 180 / .pi
                }
                let noFace = AutoAdjust.auto(source: green, inputs: Adjustments(), hints: AutoHints())
                check("a greenish face moves the tint toward magenta, within limits", g.whiteBalance!.tint > noFace.whiteBalance!.tint
                      && g.whiteBalance!.tint - noFace.whiteBalance!.tint <= AutoAdjust.maxSkinTintShift
                      && faceHue(green, g) < faceHue(green, noFace),
                      String(format: "tint %.0f -> %.0f, face hue %.1f -> %.1f", noFace.whiteBalance!.tint, g.whiteBalance!.tint,
                             faceHue(green, noFace), faceHue(green, g)))
                let nPlain = AutoAdjust.auto(source: normal, inputs: Adjustments(), hints: AutoHints())
                check("a natural skin tone leaves the tint alone", n.whiteBalance == nPlain.whiteBalance, "\(describe(nPlain)) vs \(describe(n))")
            }
            if let fine = ImageSource(url: dir.appendingPathComponent("well-exposed.jpg"), maxPixelSize: nil), let st = AutoAdjust.auto(source: fine, inputs: Adjustments()).stats {
                let ev = AutoAdjust.faceExposure(0, faceLuminance: 0.5, faceArea: 0.1, stats: st, scene: .normal)
                let dim = AutoAdjust.faceExposure(0, faceLuminance: 0.15, faceArea: 0.3, stats: st, scene: .normal)
                let night = AutoAdjust.faceExposure(0, faceLuminance: 0.15, faceArea: 0.3, stats: st, scene: .night)
                let lowKey = AutoAdjust.faceExposure(0, faceLuminance: 0.15, faceArea: 0.3, stats: st, scene: .lowKey)
                check("face exposure: alone in the band, capped outside it, off at night", ev == 0 && dim > 0 && dim <= 0.5
                      && night == 0 && lowKey <= 0.3, "\(ev) \(dim) \(night) \(lowKey)")
            }

            // Second opinion: a nudge, never a replacement.
            do {
                let t = AutoAdjust.Tone(exposure: 0.2, contrast: 10, highlights: -10, shadows: 10)
                let c = AutoAdjust.ColorBoost(vibrance: 10, saturation: 2)
                let o = AutoAdjust.SecondOpinion(exposure: 1.5, vibrance: 60, shadows: 60, highlights: -60)
                let (nt, nc) = AutoAdjust.nudged(t, c, by: o, scene: .normal, faces: false)
                check("second opinion nudges by small capped steps", abs(nt.exposure - 0.35) < 1e-9 && nt.shadows == 18 && nt.highlights == -18
                      && nc.vibrance == 15 && nt.contrast == 10 && nc.saturation == 2, "\(nt) \(nc)")
                let (wt, wc) = AutoAdjust.nudged(t, c, by: o, scene: .wellExposed, faces: false)
                let (ft, fc) = AutoAdjust.nudged(t, c, by: o, scene: .night, faces: true)
                check("second opinion leaves well-exposed photos, night tone and faces' vibrance alone", wt == t && wc == c
                      && ft.exposure == t.exposure && ft.shadows == t.shadows && ft.highlights == t.highlights && fc.vibrance <= c.vibrance, "\(ft) \(fc)")
                check("tone curve midpoint reads as EV", abs((AutoAdjust.curveValue([CGPoint(x: 0, y: 0), CGPoint(x: 0.4, y: 0.5), CGPoint(x: 1, y: 1)], at: 0.5) ?? 0) - 7.0 / 12) < 1e-9, "")
                let opinion = sceneAuto.opinion
                check("second opinion is read from Core Image", opinion != nil, "\(String(describing: opinion))")
            }

            // Auto straighten: only a confident, modest tilt; sets only the angle; ignores the crop.
            check("straighten trusts confident, modest horizons only",
                  AutoAdjust.straightenAngle(.init(angle: 4.87, confidence: 0.9)) == 4.9
                  && AutoAdjust.straightenAngle(.init(angle: -10, confidence: 0.6)) == -10
                  && AutoAdjust.straightenAngle(.init(angle: 12, confidence: 1)) == nil
                  && AutoAdjust.straightenAngle(.init(angle: 3, confidence: 0.3)) == nil
                  && AutoAdjust.straightenAngle(nil) == nil, "")
            do {
                let engine = AutoEngine()
                AutoVision.shared.install(horizon: .init(angle: -3.24, confidence: 0.95), for: url)
                var cropped = Adjustments(); cropped.crop.rect = NormRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5); cropped.exposure = 1
                let level = engine.resultNow(for: AutoRequest(url: url, kind: .straighten, adjustments: cropped))
                let again = engine.resultNow(for: AutoRequest(url: url, kind: .straighten, adjustments: Adjustments()))
                var expect = cropped; expect.crop.angle = -3.2
                check("auto straighten sets only the angle", level?.angle == -3.2 && level?.applied(to: cropped) == expect
                      && again == level && engine.measurementCount == 1, "\(String(describing: level))")
                let auto = engine.resultNow(for: AutoRequest(url: url, kind: .auto, adjustments: cropped))
                check("✦ Auto never straightens", auto?.angle == nil && auto?.applied(to: cropped).crop == cropped.crop, "")
                AutoVision.shared.install(horizon: nil, for: url)
                engine.clear()
                check("no horizon, no angle", engine.resultNow(for: AutoRequest(url: url, kind: .straighten, adjustments: Adjustments()))?.angle == nil, "")
                AutoVision.shared.removeOverrides(for: url)
            }

            // The real horizon detector, when it finds the synthetic horizon: the sign must level it.
            // (Skipped, not failed, when Vision finds nothing: the test mustn't depend on the model.)
            if let tilted = synthetic("tilted.jpg", { ctx, W, H in
                ctx.setFillColor(color(0.58, 0.45, 0.95)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                ctx.setFillColor(color(0.3, 0.5, 0.35))
                ctx.beginPath(); ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: 0, y: H * 0.4))
                ctx.addLine(to: CGPoint(x: W, y: H * 0.4 + tan(5 * .pi / 180) * W)); ctx.addLine(to: CGPoint(x: W, y: 0)); ctx.fillPath()
            }) {
                AutoVision.shared.visionEnabled = true
                let found = AutoAdjust.straighten(source: tilted)
                if let angle = found.angle {
                    // Where the ground starts (first green-over-blue row from the top) near each side.
                    func edgeRows(_ a: Adjustments) -> (Int, Int)? {
                        guard let bm = AutoAdjust.readback(tilted.developed(a, geometry: .full, renderScale: 1)) else { return nil }
                        func row(_ x: Int) -> Int {
                            for y in 0..<bm.height { let i = (y * bm.width + x) * 4; if bm.pixels[i + 1] > bm.pixels[i + 2] { return y } }
                            return bm.height
                        }
                        return (row(bm.width / 5), row(bm.width * 4 / 5))
                    }
                    var a = Adjustments(); a.crop.angle = angle
                    let before = edgeRows(Adjustments()), after = edgeRows(a)
                    check("auto straighten levels a horizon rising to the right", angle > 3 && angle < 7
                          && before.map { $0.0 - $0.1 > 30 } == true && after.map { abs($0.0 - $0.1) <= 4 } == true,
                          String(format: "angle %.1f, ", angle) + "edge rows \(String(describing: before)) -> \(String(describing: after))")
                } else {
                    print("SKIP  auto straighten sign check (Vision found no horizon: \(String(describing: found.horizon)))")
                }
                AutoVision.shared.visionEnabled = false
            }
        }

        // Learn from my edits: a nearest-neighbour average of what the user changed over ✦ Auto.
        do {
            var seed: UInt64 = 42
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
            func features() -> [Double] { (0..<StyleFeatures.count).map { _ in rnd() } }
            // A fake catalog where every edit is "+0.5 EV and +10 vibrance over auto", with a little noise.
            var model = StyleModel()
            for i in 0..<60 {
                var d = [Double](repeating: 0, count: StyleSliders.count)
                d[2] = 0.5 + (rnd() - 0.5) * 0.1; d[8] = 10 + (rnd() - 0.5) * 4; d[0] = (rnd() - 0.5) * 2
                model.set("p\(i)", features: features(), delta: d)
            }
            var worst = (ev: 0.0, vib: 0.0, other: 0.0)
            for _ in 0..<20 {
                guard let o = model.predict(features())?.values else { worst = (9, 99, 99); break }
                worst.ev = max(worst.ev, abs(o[2] - 0.5)); worst.vib = max(worst.vib, abs(o[8] - 10))
                worst.other = max(worst.other, (0..<o.count).filter { $0 != 2 && $0 != 8 }.map { abs(o[$0]) }.max() ?? 0)
            }
            check("learned style converges to +0.5 EV and +10 vibrance", worst.ev <= 0.1 && worst.vib <= 2 && worst.other <= 1,
                  String(format: "worst off by %.2f EV, %.1f vibrance, %.1f elsewhere", worst.ev, worst.vib, worst.other))

            var few = StyleModel()
            for i in 0..<(StyleModel.minimumSamples - 1) { few.set("p\(i)", features: features(), delta: [0, 0, 0.5, 0, 0, 0, 0, 0, 10, 0]) }
            let tooFew = few.predict(features())
            few.set("last", features: features(), delta: [0, 0, 0.5, 0, 0, 0, 0, 0, 10, 0])
            check("no learning below \(StyleModel.minimumSamples) edited photos", tooFew == nil && few.isActive && few.predict(features()) != nil
                  && few.predict(features(), excluding: "last") == nil, "")

            // The open photo's own entry never counts toward its own prediction, so "adapted" is
            // judged without it: exactly the minimum, one of them the photo itself, isn't enough.
            check("adapted only with enough other edited photos", few.isActive(for: "new") && !few.isActive(for: "last")
                  && few.predict(features(), excluding: "last") == nil && !few.isActive(for: "last") == (few.predict(features(), excluding: "last") == nil), "")

            var wild = StyleModel()
            for i in 0..<30 { wild.set("p\(i)", features: features(), delta: [80, -80, 3, 0, 0, 0, 0, 0, 90, 0]) }
            let clamped = wild.predict(features())?.values ?? []
            check("learned changes are clamped", clamped == [25, -20, 1.0, 0, 0, 0, 0, 0, 30, 0], "\(clamped)")

            // Nearest neighbours win: two clusters with opposite habits.
            var two = StyleModel()
            for i in 0..<30 {
                var f = features(); f[2] = 0.2 + rnd() * 0.05
                two.set("dark\(i)", features: f, delta: [0, 0, 0.6, 0, 0, 0, 0, 0, 0, 0])
                var g = features(); g[2] = 0.8 + rnd() * 0.05
                two.set("light\(i)", features: g, delta: [0, 0, -0.4, 0, 0, 0, 0, 0, 0, 0])
            }
            var q = [Double](repeating: 0.5, count: StyleFeatures.count); q[2] = 0.21
            check("similar photos decide", (two.predict(q)?.values[2] ?? 0) > 0.2, "\(String(describing: two.predict(q)))")

            // Index entries: only hand-edited photos with a current sample for the same crop.
            let sample = StyleSample(features: features(), auto: [5, 0, 0.3, 10, -5, 5, 10, -10, 12, 0], crop: CropSettings())
            var edited = Adjustments(); edited.exposure = 0.8; edited.vibrance = 22; edited.temperature = 5
            var idx = StyleModel()
            idx.update("a", sample: sample, adjustments: edited)
            let delta = idx.entries["a"]?.delta ?? []
            idx.update("b", sample: sample, adjustments: Adjustments())
            var recropped = edited; recropped.crop.rect = NormRect(x: 0, y: 0, width: 0.5, height: 0.5)
            idx.update("c", sample: sample, adjustments: recropped)
            var old = sample; old.version = 0
            idx.update("d", sample: old, adjustments: edited)
            check("only hand-edited photos with a current sample are learned from", idx.count == 1
                  && abs(delta[2] - 0.5) < 1e-9 && delta[8] == 10 && delta[3] == -10, "\(delta)")

            do {
                let f = StyleFeatures.make(AutoAdjust.auto(source: src, inputs: Adjustments()), isRAW: false) ?? []
                check("style features are a dozen finite numbers", f.count == StyleFeatures.count && f.allSatisfy { $0.isFinite && abs($0) <= 1.0001 }, "\(f)")
            }
            var adapted = AutoResult(); adapted.learned = StyleOffset(values: [0, 0, 0.5, 0, 0, 0, 0, 0, 10, 0])
            var start = Adjustments(); start.exposure = 4.8; start.vibrance = 95
            let applied = adapted.applied(to: start)
            check("a learned offset stays within slider ranges", applied.exposure == 5 && applied.vibrance == 100, "")

            // Catalogs from before learning still load; a bad sample is dropped on its own.
            let oldCatalog = #"{"version":1,"folders":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","path":"/tmp/x"}],"fingerprints":{"a":"b"}}"#
            let newCatalog = #"{"version":1,"folders":[],"styleSamples":{"good":{"version":1,"features":[0,0,0,0,0,0,0,0,0,0,0,0],"auto":[0,0,0,0,0,0,0,0,0,0]},"bad":{"version":1,"auto":[1]}}}"#
            let report = DecodeReport()
            let o = try? JSONDecoder.reporting(into: DecodeReport()).decode(Catalog.self, from: Data(oldCatalog.utf8))
            let n = try? JSONDecoder.reporting(into: report).decode(Catalog.self, from: Data(newCatalog.utf8))
            check("catalogs without style samples still load", o?.folders.count == 1 && o?.styleSamples.isEmpty == true && o?.fingerprints["a"] == "b", "")
            check("a malformed style sample is dropped on its own", n?.styleSamples.count == 1 && n?.styleSamples["good"]?.crop == CropSettings()
                  && n?.styleSamples["good"]?.isUsable(crop: CropSettings()) == true && report.dropped == 1, "dropped \(report.dropped)")
            var cat = Catalog(); cat.styleSamples["k"] = sample
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let back = (try? enc.encode(cat)).flatMap { try? dec.decode(Catalog.self, from: $0) }
            check("style samples round-trip", back?.styleSamples["k"]?.features == sample.features && back?.styleSamples["k"]?.auto == sample.auto, "")
        }

        // Export keeps metadata (optionally without location), and parallel exports never share a name.
        let exportDir = dir.appendingPathComponent("export-out")
        try? FileManager.default.removeItem(at: exportDir)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let tagged = dir.appendingPathComponent("tagged.jpg")
        if let d = CGImageDestinationCreateWithURL(tagged as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            let props: [CFString: Any] = [
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:06:01 18:30:00", kCGImagePropertyExifLensModel: "Test 35mm"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                                kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E"],
            ]
            CGImageDestinationAddImage(d, img, props as CFDictionary)
            CGImageDestinationFinalize(d)
        }
        func props(_ u: URL) -> [CFString: Any] {
            CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        }
        var es = ExportSettings(); es.longEdge = 800
        if let out = try? Exporter.export((tagged, Adjustments()), settings: es, to: exportDir) {
            let p = props(out), exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
            check("export keeps capture date and lens", exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:06:01 18:30:00"
                  && exif?[kCGImagePropertyExifLensModel] as? String == "Test 35mm", "\(exif ?? [:])")
            check("export keeps location by default", p[kCGImagePropertyGPSDictionary] != nil, "")
            check("export orientation is upright", (p[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "")
        } else { check("export with metadata", false, "export failed") }
        es.stripLocation = true
        if let out = try? Exporter.export((tagged, Adjustments()), settings: es, to: exportDir) {
            let p = props(out)
            check("export can remove location", p[kCGImagePropertyGPSDictionary] == nil
                  && (p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] != nil, "")
        }
        let parallelDir = exportDir.appendingPathComponent("parallel")
        try? FileManager.default.createDirectory(at: parallelDir, withIntermediateDirectories: true)
        var parallelOut: [URL] = []
        var parallelDone = false
        Task {
            let r = await Exporter.exportAll(Array(repeating: (tagged, Adjustments()), count: 4), settings: es, to: parallelDir, concurrency: 2) { _ in }
            parallelOut = r.compactMap { try? $0.result.get() }
            parallelDone = true
        }
        while !parallelDone { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check("parallel exports get distinct names", Set(parallelOut.map(\.lastPathComponent)).count == 4
              && parallelOut.allSatisfy { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0) > 1000 },
              parallelOut.map(\.lastPathComponent).joined(separator: ", "))

        // Selective paste: all groups together copy everything; one group copies only itself.
        var full = Adjustments()
        full.exposure = 1; full.contrast = 10; full.highlights = -20; full.shadows = 20; full.whites = 5; full.blacks = -5
        full.temperature = 12; full.tint = -3; full.vibrance = 15; full.saturation = -10
        full.grading.shadows.saturation = 30; full.curve = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]
        full.hsl[2].hue = 20; full.sharpening = 40; full.noiseReduction = 20; full.vignette = -30
        full.masks = [Mask(name: "R", kind: .radial)]; full.crop.angle = 3
        check("paste with every group copies everything", Adjustments().copying(Set(SettingsGroup.allCases), from: full) == full, "")
        let onlyLight = Adjustments().copying([.light], from: full)
        check("paste one group copies only it", onlyLight.exposure == 1 && onlyLight.temperature == 0 && onlyLight.masks.isEmpty
              && onlyLight.crop == CropSettings(), "")

        // LUT speed (rebuilt on every curve/HSL/wheel drag).
        let t0 = Date()
        var key = ColorLUTKey(Adjustments()); key.contrast = 13; key.hsl[2].hue = 20; key.grading.midtones.saturation = 30
        _ = ColorLUT.cubeData(for: key)
        let ms = Date().timeIntervalSince(t0) * 1000
        check("LUT builds fast", ms < 15, String(format: "%.1f ms", ms))

        print(ok ? "ALL PASSED" : "SOME FAILED")
        return ok
    }
}

/// Minimal HSB → RGB without AppKit color management.
enum NSColorShim {
    static func hsb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

/// Output folders for `--selftest` and `--snapshot`, which delete and recreate things inside them.
enum TestOutput {
    static let marker = ".halfstop-test-output"

    /// True when `dir` is safe to use: it didn't exist (it's created), is an empty folder, or holds
    /// the marker from an earlier run. The marker is written so later runs can reuse it. Anything
    /// else (a home folder, a link, a folder with other files) is refused and left untouched.
    static func claim(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let markerURL = dir.appendingPathComponent(marker)
        switch LibraryFiles.kind(dir) {
        case nil:
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return false }
        case .directory:
            if LibraryFiles.kind(markerURL) == .file { return true }
            let contents = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).filter { $0 != ".DS_Store" }
            guard contents.isEmpty else { return false }
        default:
            return false
        }
        return (try? Data("Made by Halfstop --selftest / --snapshot. Its contents may be deleted.\n".utf8).write(to: markerURL)) != nil
    }
}

/// `Halfstop --snapshot <dir>`: drives the UI through its main states and saves window captures.
/// The Metal preview is drawn separately (window caching can't read Metal layers).
@MainActor
enum Snapshot {
    static var outputDir: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    /// `--catalog <path>` points the app at a different library index (used by snapshots).
    nonisolated static var catalogOverride: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--catalog"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    nonisolated static var samplesFolder: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--samples"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    /// The curve, hue curve, effects, lens, spot removal and mask range panels. Panel sections are
    /// opened through their saved open/closed state, which is put back afterwards.
    static func newToolShots(store: LibraryStore, shot: @MainActor (String, Bool) -> Void, preview: @MainActor (String) -> Void,
                             wait: (Double) async -> Void) async {
        let d = UserDefaults.standard
        let keys = ["sec.masks", "sec.light", "sec.color", "sec.grading", "sec.curve", "sec.hsl", "sec.detail", "sec.effects",
                    "sec.lens", "sec.spots", "curve.mode", "curve.channel", "hsl.curves"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        func only(_ open: [String]) { for k in keys where k.hasPrefix("sec.") { d.set(open.contains(k), forKey: k) } }

        store.activeMaskID = nil
        store.panelTab = .detailed
        only(["sec.curve"])
        d.set(false, forKey: "curve.mode"); d.set(1, forKey: "curve.channel")
        store.edit { $0.curveRed = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.45, y: 0.55), CurvePoint(x: 1, y: 1)]
            $0.curve = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.8), CurvePoint(x: 1, y: 1)] }
        store.checkpoint()
        await wait(1.2)
        shot("13-curve-red", false)
        d.set(true, forKey: "curve.mode")
        store.edit { $0.parametric.shadows = 30; $0.parametric.highlights = -25 }
        store.checkpoint()
        await wait(1)
        shot("13b-curve-parametric", false)

        only(["sec.hsl"])
        d.set(true, forKey: "hsl.curves")
        store.hueCurveChannel = .saturation
        store.setHueCurve(at: 215, to: 0.15)
        store.checkpoint()
        store.targetAdjusting = true
        await wait(1.2)
        shot("14-hue-curves", false)
        preview("14-hue-curves")
        store.targetAdjusting = false

        only(["sec.light", "sec.effects", "sec.lens"])
        store.edit { $0.clarity = 30; $0.dehaze = 25; $0.grain.amount = 35; $0.lens.removeFringing = true; $0.lens.vignetting = 30 }
        store.checkpoint()
        await wait(1.2)
        shot("15-presence-effects-lens", false)
        preview("15-presence-effects-lens")

        only(["sec.spots"])
        store.removingSpots = true
        store.addSpot(center: NormPoint(x: 0.3, y: 0.3), source: NormPoint(x: 0.36, y: 0.3))
        store.addSpot(center: NormPoint(x: 0.6, y: 0.2), source: NormPoint(x: 0.6, y: 0.27))
        await wait(1.2)
        shot("16-remove-spots", false)
        store.removingSpots = false

        only(["sec.masks", "sec.light"])
        store.addMask(.radial)
        store.editMask { $0.radiusX = 0.6; $0.radiusY = 0.6; $0.local.exposure = 0.8
            var r = MaskRange(kind: .luminance); r.low = 0.55; r.smoothness = 0.1; $0.range = r }
        store.setOverlay(true)
        await wait(1.5)
        shot("17-mask-brightness-range", false)
        preview("17-mask-brightness-range")
        store.setOverlay(false)
        store.activeMaskID = nil
    }

    static func run(store: LibraryStore, renderer: PreviewRenderer) {
        guard let dir = outputDir else { return }
        guard TestOutput.claim(dir) else {
            print("--snapshot: \(dir.path) isn't empty and wasn't made by a snapshot run. Choose a new or empty folder.")
            return
        }
        Task { @MainActor in
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            @MainActor func shot(_ name: String, sheet: Bool = false) {
                let window = NSApp.windows.first { $0.isVisible && (sheet ? $0.sheetParent != nil : $0.sheetParent == nil) && $0.contentView != nil }
                guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("no window for \(name)"); return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                print("snapshot \(name)")
            }
            @MainActor func preview(_ name: String) {
                guard let p = store.current, let src = renderer.source(for: p.url) else { print("no preview"); return }
                let neutral = store.activeMask?.local.isNeutral ?? false
                let img = src.developed(p.adjustments, geometry: store.activeMaskID != nil ? .none : .full,
                                        overlayMask: (store.showMaskOverlay || neutral) ? store.activeMaskID : nil)
                try? Render.background.writeJPEGRepresentation(of: img, to: dir.appendingPathComponent(name + ".jpg"),
                                                               colorSpace: Render.sRGB, options: [:])
            }
            await wait(1.5)
            // Work on a private copy so snapshots never touch real sidecars.
            var samplesCopy: URL?
            if let samples = samplesFolder {
                let copy = dir.appendingPathComponent("photos")
                try? FileManager.default.removeItem(at: copy)
                try? FileManager.default.copyItem(at: samples, to: copy)
                try? FileManager.default.removeItem(at: copy.appendingPathComponent(SidecarFiles.folderName))
                // A photo with two clear subjects for the subject-mask step.
                if let ctx = CGContext(data: nil, width: 1800, height: 1200, bitsPerComponent: 8, bytesPerRow: 0, space: Render.sRGB,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.78, blue: 0.72, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1800, height: 1200))
                    ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.15, blue: 0.1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 200, y: 350, width: 420, height: 420))
                    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.85, alpha: 1)); ctx.fill(CGRect(x: 1200, y: 300, width: 380, height: 520))
                    if let img = ctx.makeImage() { SelfTest.write(img, to: copy.appendingPathComponent("zz-subjects.jpg")) }
                }
                samplesCopy = copy
            }
            if !store.hasLibrary, let samples = samplesCopy {
                let portfolio = store.createCollection(named: "Portfolio")
                store.createCollection(named: "Print queue")
                let scan = await store.scanForImport(samples, includeSubfolders: true)
                var opts = ImportOptions()
                opts.collection = portfolio
                _ = await store.performImport(scan, options: opts)
                if let pq = store.catalog.collections.first(where: { $0.name == "Print queue" }) {
                    store.addToCollection(pq.id, Array(store.photos.prefix(2)))
                    store.setTargetCollection(pq.id)
                }
            }
            store.source = .all
            await wait(0.5)
            if let first = store.visiblePhotos.first { store.select(first) }
            store.setRating(4); store.setFlag(.pick)
            store.step(1); store.setFlag(.reject)
            await wait(2)
            shot("1-library-sidebar")

            store.showImportSheet(prefill: samplesCopy)
            await wait(2.5)
            shot("2-import-sheet", sheet: true)
            store.showImport = false
            await wait(0.8)

            if let pq = store.catalog.collections.first(where: { $0.name == "Print queue" }) {
                store.source = .collection(pq.id)
            }
            await wait(1)
            shot("3-collection")

            store.source = .all
            store.mode = .edit
            await wait(2)
            // The Basic panel with its auto row, then after ✦ Auto.
            let tab = store.panelTab
            store.panelTab = .quick
            await wait(0.5)
            shot("3b-basic-panel")
            _ = await store.runAuto(.auto)?.value
            await wait(0.8)
            shot("3c-after-auto")
            store.undo()
            // The crop panel with Auto straighten (the samples have no horizon: its hint shows).
            store.isCropping = true
            await wait(0.8)
            _ = await store.runAuto(.straighten)?.value
            await wait(0.3)
            shot("3d-crop-auto-straighten")
            store.isCropping = false
            store.panelTab = tab
            await wait(0.5)
            store.addMask(.brush)
            var s1 = BrushStroke(radius: 0.05, feather: 0.4)
            s1.points = [NormPoint(x: 0.15, y: 0.25), NormPoint(x: 0.3, y: 0.3), NormPoint(x: 0.4, y: 0.25)]
            var s2 = BrushStroke(radius: 0.05, feather: 0.4)
            s2.points = [NormPoint(x: 0.7, y: 0.75)]
            store.editMask { $0.strokes.append(s1) }
            store.editMask { $0.strokes.append(s2) }
            await wait(1.5)
            shot("4-brush-mask")
            preview("4-brush-mask-preview")

            store.addMask(.linear)
            store.editMask { $0.start = NormPoint(x: 0.95, y: 0.5); $0.end = NormPoint(x: 0.7, y: 0.5); $0.local.exposure = -1 }
            store.addShape(.linear) { $0.start = NormPoint(x: 0.05, y: 0.5); $0.end = NormPoint(x: 0.3, y: 0.5) }
            store.setOverlay(true)
            await wait(1.5)
            shot("4b-two-linears")
            preview("4b-two-linears")
            store.setOverlay(false)

            await newToolShots(store: store, shot: shot, preview: preview, wait: wait)

            if let subjects = store.visiblePhotos.first(where: { $0.name == "zz-subjects.jpg" }) {
                store.select(subjects)
                await wait(2.5)
                store.addMask(.subject)
                await wait(4)
                shot("5-subject-mask")
                preview("5-subject-all")
                if let url = store.currentID, let n = SubjectDetector.shared.subjectCount(url) {
                    print("subjects found: \(n)")
                    if n > 1 { store.setSubject(2, included: false, count: n) }
                    store.editMask { $0.strokes = [BrushStroke(points: [NormPoint(x: 0.12, y: 0.15), NormPoint(x: 0.3, y: 0.15)], radius: 0.04, feather: 0.3)] }
                }
                await wait(1.5)
                shot("6-subject-one-refined")
                preview("6-subject-one-refined")
                store.editMask { $0.local.exposure = 0.6 }
                store.checkpoint()
                store.activeMaskID = nil
                store.edit { $0.contrast = 18 }
                store.checkpoint()
                store.edit { $0.temperature = 25 }
                store.checkpoint()
                store.saveSnapshot(named: "Warm version")
                store.edit { $0.saturation = -20 }
                store.checkpoint()
                store.jumpToStep(max(0, (store.current?.history.count ?? 2) - 3))
                await wait(1.2)
                shot("9-history")
            }

            store.mode = .library
            store.source = .all
            store.saveNow()
            await wait(2)
            shot("7-library-edited")
            store.editsFilter = .edited
            await wait(1)
            shot("8-edited-filter")
            store.editsFilter = .any
            // The Move to Trash warning (cancelled: nothing is trashed).
            store.requestTrash(Array(store.visiblePhotos.prefix(3)))
            await wait(1)
            shot("10-trash-warning", sheet: true)
            shot("10-trash-warning-window")
            store.trashRequest = nil
            await wait(0.5)
            // Help window, rendered in its own window.
            let help = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680), styleMask: [.titled, .fullSizeContentView],
                                backing: .buffered, defer: false)
            help.titlebarAppearsTransparent = true
            help.appearance = NSAppearance(named: .darkAqua)
            help.contentView = NSHostingView(rootView: HelpView().preferredColorScheme(.dark))
            help.orderFront(nil)
            await wait(1)
            if let view = help.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("11-help.png"))
                print("snapshot 11-help")
            }
            help.close()
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled],
                                    backing: .buffered, defer: false)
            settings.appearance = NSAppearance(named: .darkAqua)
            settings.contentView = NSHostingView(rootView: SettingsView().environment(store).preferredColorScheme(.dark))
            settings.orderFront(nil)
            await wait(1)
            settings.setContentSize(settings.contentView?.fittingSize ?? settings.frame.size)
            await wait(0.5)
            if let view = settings.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("12-settings.png"))
                print("snapshot 12-settings")
            }
            settings.close()
            store.flushSaves()
            print("snapshot done")
            NSApp.terminate(nil)
        }
    }
}

/// Import, rename, duplicates, collections, relocation and persistence, against a throwaway catalog.
@MainActor
enum LibraryTest {
    static func run(dir: URL) async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let a = dir.appendingPathComponent("Trip A"), b = dir.appendingPathComponent("Card B")
        try? fm.createDirectory(at: a.appendingPathComponent("day2"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: b, withIntermediateDirectories: true)
        for i in 0..<4 {
            if let img = SelfTest.scene(width: 600, height: 400, hue: Double(i) / 5, variant: i) {
                SelfTest.write(img, to: a.appendingPathComponent("IMG_\(100 + i).jpg"))
            }
        }
        if let img = SelfTest.scene(width: 600, height: 400, hue: 0.9, variant: 7) { SelfTest.write(img, to: a.appendingPathComponent("day2/IMG_200.jpg")) }
        // Card B: two copies of A's photos under new names, plus one new photo.
        try? fm.copyItem(at: a.appendingPathComponent("IMG_100.jpg"), to: b.appendingPathComponent("DSC_1.jpg"))
        try? fm.copyItem(at: a.appendingPathComponent("IMG_101.jpg"), to: b.appendingPathComponent("DSC_2.jpg"))
        if let img = SelfTest.scene(width: 600, height: 400, hue: 0.33, variant: 9) { SelfTest.write(img, to: b.appendingPathComponent("DSC_3.jpg")) }

        var ok = true
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print("\(cond ? "PASS" : "FAIL")  \(name)  \(detail)")
            if !cond { ok = false }
        }
        func reloaded(_ store: LibraryStore) async { await withCheckedContinuation { c in store.reload { c.resume() } } }

        let catalogURL = dir.appendingPathComponent("catalog.json")
        let store = LibraryStore(catalogURL: catalogURL, watch: false)
        await reloaded(store)
        check("empty library starts empty", store.photos.isEmpty)

        let best = store.createCollection(named: "Best")!
        var preset = Adjustments(); preset.exposure = 1
        let scanA = await store.scanForImport(a, includeSubfolders: true)
        check("scan finds photos in subfolders", scanA.files.count == 5, "\(scanA.files)")
        var opts = ImportOptions()
        opts.preset = Preset(name: "Bright", adjustments: preset)
        opts.rename = .nameSequence
        opts.customName = "trip"
        opts.collection = best
        let resA = await store.performImport(scanA, options: opts)
        check("import A brings in 5", resA.imported == 5 && store.photos.count == 5, "\(resA)")
        check("files renamed on disk", fm.fileExists(atPath: a.appendingPathComponent("trip-001.jpg").path)
              && !fm.fileExists(atPath: a.appendingPathComponent("IMG_100.jpg").path), "renamed \(resA.renamed)")
        check("subfolder file renamed in place", fm.fileExists(atPath: a.appendingPathComponent("day2").path)
              && (try? fm.contentsOfDirectory(atPath: a.appendingPathComponent("day2").path))?.contains { $0.hasPrefix("trip-") } == true)
        check("preset applied via sidecars", store.photos.allSatisfy { $0.adjustments.exposure == 1 })
        check("added to collection", store.count(.collection(best)) == 5)
        check("last import shows A", store.source == .lastImport && store.count(.lastImport) == 5)

        // Edit one photo, then revert names: the edit and membership must follow the file.
        store.photos.first?.rating = 4
        if let p = store.photos.first { store.scheduleSave(p) }
        store.flushSaves()
        await store.revertLastImportNames()
        check("revert restores original names", fm.fileExists(atPath: a.appendingPathComponent("IMG_100.jpg").path)
              && !fm.fileExists(atPath: a.appendingPathComponent("trip-001.jpg").path))
        check("collection survives revert", store.count(.collection(best)) == 5)
        check("rating survives revert", store.photos.contains { $0.rating == 4 })
        check("preset survives revert", store.photos.allSatisfy { $0.adjustments.exposure == 1 })

        let scanB = await store.scanForImport(b, includeSubfolders: true)
        check("duplicates detected by content", scanB.duplicates.count == 2 && scanB.newFiles(skipDuplicates: true).count == 1,
              "dups \(scanB.duplicates.sorted())")
        let resB = await store.performImport(scanB, options: ImportOptions())
        check("import B skips duplicates", resB.imported == 1 && store.photos.count == 6, "\(resB)")
        let again = await store.scanForImport(b, includeSubfolders: true)
        check("re-import finds nothing new", again.newFiles(skipDuplicates: true).isEmpty)
        let inside = await store.scanForImport(a.appendingPathComponent("day2"), includeSubfolders: true)
        check("subfolder of imported folder is recognized", inside.coveredBy == "Trip A" && inside.newFiles(skipDuplicates: true).isEmpty)

        // Collections.
        let picks = store.createCollection(named: "Picks")!
        let bPhoto = store.photos.first { $0.url.path.contains("Card B") }!
        store.addToCollection(picks, [bPhoto, store.photos[0]])
        store.addToCollection(picks, [bPhoto])
        check("collection ignores repeat adds", store.count(.collection(picks)) == 2)
        store.removeFromCollection(picks, [store.photos[0]])
        check("remove from collection", store.count(.collection(picks)) == 1)
        check("B targets newest collection", store.targetCollection?.id == picks)

        // Move folder B on disk, then relocate.
        let moved = dir.appendingPathComponent("Card B moved")
        try? fm.moveItem(at: b, to: moved)
        await reloaded(store)
        let bFolder = store.catalog.folders.first { $0.name == "Card B" }!
        check("moved folder shows missing", !bFolder.exists && store.photos.count == 5)
        store.relocateFolder(bFolder.id, to: moved)
        await reloaded(store)
        check("relocated folder comes back", store.photos.count == 6)
        check("collection survives relocation", store.count(.collection(picks)) == 1)

        // Persistence.
        let fresh = LibraryStore(catalogURL: catalogURL, watch: false)
        await reloaded(fresh)
        check("catalog persists", fresh.photos.count == 6 && fresh.catalog.collections.count == 2
              && fresh.count(.collection(best)) == 5, "\(fresh.photos.count) photos")

        store.deleteCollection(picks)
        check("delete collection keeps photos", store.catalog.collections.count == 1 && store.photos.count == 6)
        store.removeFolder(bFolder.id)
        await reloaded(store)
        check("remove folder drops its photos only", store.photos.count == 5 && fm.fileExists(atPath: moved.appendingPathComponent("DSC_3.jpg").path))

        // Edit history.
        if let photo = store.photos.first {
            store.mode = .edit
            store.select(photo)
            store.resetAdjustments()
            store.clearHistory()
            let base = photo.history.count
            store.edit { $0.exposure = 0.5 }
            store.edit { $0.exposure = 1 }          // same gesture: merges
            store.checkpoint()                       // new gesture starts
            store.edit { $0.contrast = 20 }
            store.commitPending(photo)
            check("one gesture = one step", photo.history.count == base + 2, photo.history.map(\.label).joined(separator: " | "))
            check("step labels read well", photo.history.suffix(2).map(\.label) == ["Exposure +1.00", "Contrast +20"],
                  photo.history.suffix(2).map(\.label).joined(separator: " | "))
            store.jumpToStep(base)
            check("jump back restores that state", photo.adjustments.exposure == 1 && photo.adjustments.contrast == 0
                  && photo.history.count == base + 2, "")
            store.edit { $0.saturation = -30 }
            store.commitPending(photo)
            check("editing after a jump trims later steps", photo.history.map(\.label).suffix(2) == ["Exposure +1.00", "Saturation -30"],
                  photo.history.map(\.label).joined(separator: " | "))
            store.undo()
            check("undo steps back", photo.adjustments.saturation == 0 && photo.historyIndex == base)
            store.redo()
            check("redo steps forward", photo.adjustments.saturation == -30)
            store.saveSnapshot(named: "Muted")
            store.edit { $0.saturation = 40 }
            store.commitPending(photo)
            if let snap = photo.snapshots.first { store.applySnapshot(snap) }
            check("snapshot restores and is a step", photo.adjustments.saturation == -30 && photo.history.last?.label == "Snapshot: Muted",
                  photo.history.last?.label ?? "")
            store.addMask(.linear)
            store.commitPending(photo)
            check("mask steps are labelled", photo.history.last?.label == "Add mask: Linear 1", photo.history.last?.label ?? "")
            let count = photo.history.count, index = photo.historyIndex
            store.flushSaves()
            let reopened = LibraryStore(catalogURL: catalogURL, watch: false)
            await reloaded(reopened)
            let again = reopened.photos.first { $0.url == photo.url }
            check("history and snapshots persist", again?.history.count == count && again?.historyIndex == index
                  && again?.snapshots.first?.name == "Muted", "\(again?.history.count ?? -1) steps")
            store.clearHistory()
            check("clear keeps current edits", photo.history.count == 1 && photo.adjustments.saturation == -30)
            store.resetAdjustments()
            store.mode = .library
        }

        // Standard selection: ⌘A, deselect, ⇧-arrows, drag box, and the filmstrip in the editor.
        let all = store.visiblePhotos
        if all.count >= 3 {
            store.mode = .library
            store.select(all[0])
            store.selectAll()
            check("⌘A selects every photo in view", store.selectedPhotos.count == all.count && store.targets.count == all.count)
            store.deselectAll()
            check("deselect all leaves only the current photo to act on", store.selection.isEmpty
                  && store.selectedPhotos.map(\.url) == [all[0].url])
            store.select(all[0])
            store.extendSelection(by: 1)
            store.extendSelection(by: 1)
            check("⇧→ extends the selection from the anchor", Set(store.selectedPhotos.map(\.url)) == Set(all[0...2].map(\.url))
                  && store.currentID == all[2].url)
            store.extendSelection(by: -1)
            check("⇧← shrinks it back toward the anchor", Set(store.selectedPhotos.map(\.url)) == Set(all[0...1].map(\.url)))
            store.select(all[0])
            store.selectBox([all[1].url, all[2].url], adding: [])
            store.finishBoxSelection()
            check("a drag box selects what it touches", store.selection == Set([all[1].url, all[2].url]) && store.currentID == all[1].url)
            store.selectBox([all[0].url], adding: store.selection)
            check("⇧-drag adds to the selection", store.selection == Set(all[0...2].map(\.url)))

            store.mode = .edit
            store.select(all[0])
            check("editor: one photo acts on the photo on screen", store.targets.map(\.url) == [all[0].url])
            store.select(all[2], extend: true)
            check("editor: ⇧-click in the filmstrip selects the range", Set(store.targets.map(\.url)) == Set(all[0...2].map(\.url)))
            store.select(all[1], toggle: true)
            check("editor: ⌘-click takes one out", Set(store.selectedPhotos.map(\.url)) == [all[0].url, all[2].url])
            store.step(1)
            check("editor: an arrow key goes back to one photo", store.targets.count == 1 && store.selection.count == 1)
            store.mode = .library
            store.select(all[0])
        } else {
            check("selection test has photos", false, "\(all.count) visible")
        }

        // Auto and presets over a library selection: each photo measured on its own, one step each.
        let picked = Array(store.visiblePhotos.prefix(3))
        if picked.count == 3 {
            store.mode = .library
            for p in picked { store.select(p); store.resetAdjustments(); store.commitPending(p) }
            store.select(picked[0])
            store.select(picked[2], extend: true)
            check("the menu acts on a ⇧-click selection", store.selectedPhotos.map(\.url) == picked.map(\.url))
            let steps = picked.map(\.history.count), before = picked.map(\.adjustments)
            let task = store.runAuto(.tone, on: store.selectedPhotos)
            check("batch auto runs in the background", task != nil && store.batchAuto?.total == 3 && picked[0].adjustments == before[0])
            check("batch auto ignores a second start", store.runAuto(.auto, on: picked) == nil)
            let changed = await task?.value ?? 0
            check("batch auto gives each photo one step", changed == 3 && store.batchAuto == nil
                  && zip(picked, steps).allSatisfy { $0.history.count == $1 + 1 && $0.history.last?.label == "Auto tone" },
                  "\(changed) changed")
            for p in picked { store.select(p); store.undo() }
            check("each photo's batch step undoes on its own", zip(picked, before).allSatisfy { $0.adjustments == $1 })

            let stopped = store.runAuto(.whiteBalance, on: picked)
            store.cancelBatchAuto()
            let stoppedCount = await stopped?.value ?? -1
            check("stopping a batch leaves the rest alone", stoppedCount == 0 && store.batchAuto == nil
                  && zip(picked, before).allSatisfy { $0.adjustments == $1 }, "\(stoppedCount) changed")

            var look = Adjustments(); look.exposure = 0.7
            store.apply(Preset(name: "Test look", adjustments: look), to: picked)
            check("a preset applies to every selected photo",
                  picked.allSatisfy { $0.adjustments.exposure == 0.7 && $0.history.last?.label == "Preset: Test look" })

            // Presets with masks.
            var source = Adjustments(); source.exposure = 0.4
            let fade = Mask(name: "Sky fade", kind: .linear)
            var person = Mask(name: "Subject", kind: .subject); person.subjects = [2]
            source.masks = [fade, person]
            let plain = source.presetLook(includeMasks: false)
            check("a preset saved without masks has none", plain.masks.isEmpty && plain.exposure == 0.4)
            let masked = source.presetLook(includeMasks: true)
            check("a preset saved with masks keeps them, subject masks for every subject",
                  masked.masks.count == 2 && masked.masks[0] == fade && masked.masks[1].subjects == nil)
            var target = Adjustments(); let own = Mask(name: "Own", kind: .radial); target.masks = [own]
            let once = masked.asPreset(onto: target)
            check("applying it adds its masks after the photo's own", once.masks.map(\.name) == ["Own", "Sky fade", "Subject"]
                  && once.masks[0] == own && once.exposure == 0.4 && once.masks[1].id != fade.id,
                  once.masks.map(\.name).joined(separator: ", "))
            let twice = masked.asPreset(onto: once)
            check("applying it twice gives distinct masks", Set(twice.masks.map(\.id)).count == 5)
            check("a preset without masks leaves the photo's masks alone", plain.asPreset(onto: target).masks == [own])
            store.apply(Preset(name: "Masked", adjustments: masked), to: picked)
            check("a preset with masks adds them to every selected photo", picked.allSatisfy { $0.adjustments.masks.count == 2 })
            for p in picked { store.select(p); store.resetAdjustments(); store.commitPending(p) }
        } else {
            check("batch auto test has photos", false, "\(picked.count) visible")
        }

        // Auto actions: measured off the main thread, applied as one step, dropped when stale.
        if store.photos.count >= 2 {
            let photo = store.photos[0], other = store.photos[1]
            store.mode = .edit
            store.select(photo)
            store.resetAdjustments()
            store.commitPending(photo)
            let steps = photo.history.count, before = photo.adjustments
            let task = store.runAuto(.tone)
            check("auto runs in the background", task != nil && photo.adjustments == before && store.isAutoRunning)
            check("auto ignores a second tap while running", store.runAuto(.whiteBalance) == nil)
            let applied = await task?.value ?? false
            check("auto tone is one labelled step", applied && !store.isAutoRunning && photo.history.count == steps + 1
                  && photo.history.last?.label == "Auto tone" && photo.adjustments != before,
                  photo.history.suffix(2).map(\.label).joined(separator: " | "))
            store.undo()
            check("auto tone undoes in one step", photo.adjustments == before)

            let all = await store.runAuto(.auto)?.value ?? false
            check("✦ Auto is one step labelled Auto", all && photo.history.count == steps + 1 && photo.history.last?.label == "Auto",
                  photo.history.suffix(2).map(\.label).joined(separator: " | "))
            store.undo()
            check("✦ Auto undoes in one step", photo.adjustments == before)

            let stale = store.runAuto(.whiteBalance)
            store.edit { $0.vignette = -20 }
            let staleApplied = await stale?.value ?? true
            check("auto result is dropped when the edits changed", !staleApplied && photo.adjustments.vignette == -20
                  && photo.adjustments.temperature == before.temperature)

            store.commitPending(photo)
            let otherSteps = other.history.count, otherBefore = other.adjustments
            let moved = store.runAuto(.tone)
            store.select(other)
            check("another photo's row isn't blocked", !store.isAutoRunning)
            let movedApplied = await moved?.value ?? true
            check("auto result is dropped after switching photos", !movedApplied && other.history.count == otherSteps
                  && other.adjustments == otherBefore && photo.adjustments.exposure == before.exposure)
            store.select(photo)

            // Auto straighten: one step that sets only the angle; without a horizon, a hint and no step.
            store.resetAdjustments()
            store.commitPending(photo)
            AutoEngine.shared.clear()
            AutoVision.shared.install(horizon: .init(angle: 2.54, confidence: 0.9), for: photo.url)
            let flat = photo.adjustments, flatSteps = photo.history.count
            let leveled = await store.performAuto(.straighten)?.value
            var expect = flat; expect.crop.angle = 2.5
            check("auto straighten is one step that sets only the angle", leveled == .applied && photo.adjustments == expect
                  && photo.history.count == flatSteps + 1 && photo.history.last?.label == "Auto straighten",
                  "\(String(describing: leveled)) angle \(photo.adjustments.crop.angle)")
            store.undo()
            AutoEngine.shared.clear()
            AutoVision.shared.install(horizon: nil, for: photo.url)
            let none = await store.performAuto(.straighten)?.value
            check("no horizon: a hint and no step", none == .noHorizon && store.hint == "No horizon found"
                  && photo.adjustments == flat && photo.history.count == flatSteps + 1, "\(String(describing: none))")
            AutoVision.shared.removeOverrides(for: photo.url)
            AutoEngine.shared.clear()

            // Learn from my edits, through the store: a background sample after an edit, then ✦ Auto
            // adapted by a fake catalog of "+0.5 EV and +10 vibrance" edits, and plain when off.
            // (The setting lives in the user's defaults: put it back exactly as it was.)
            let userSetting = UserDefaults.standard.object(forKey: LibraryStore.learnFromEditsKey)
            store.learnFromEdits = true
            store.resetAdjustments()
            store.edit { $0.exposure = 0.3; $0.vibrance = 7 }
            store.commitPending(photo)
            await store.measureStyleSample(photo.url)?.value
            let sample = store.catalog.styleSamples[photo.ref.key]
            let entry = store.styleModel.entries[photo.ref.key]
            check("an edited photo's style sample is measured and indexed", sample?.isUsable(crop: photo.adjustments.crop) == true
                  && entry.map { abs($0.delta[2] - (0.3 - sample!.auto[2])) < 1e-9 && $0.delta[8] == 7 - sample!.auto[8] } == true,
                  "\(String(describing: sample))")
            store.flushSaves()
            let saved = Catalog.load(from: catalogURL).styleSamples[photo.ref.key]
            check("style samples are saved in the catalog", sample != nil && saved?.features == sample?.features && saved?.auto == sample?.auto
                  && saved?.crop == sample?.crop)

            store.resetAdjustments()
            store.commitPending(photo)
            check("a reset photo leaves the index", store.styleModel.entries[photo.ref.key] == nil && !store.autoIsAdapted)
            let plainResult = AutoEngine.shared.resultNow(for: AutoRequest(url: photo.url, kind: .auto, adjustments: photo.adjustments))
            let plain = plainResult?.applied(to: photo.adjustments) ?? Adjustments()
            if let pf = plainResult.flatMap({ StyleFeatures.make($0, isRAW: false) }) {
                for i in 0..<25 {
                    store.styleModel.set("fake\(i)", features: pf.map { $0 + Double(i % 5) * 0.01 },
                                         delta: [0, 0, 0.5, 0, 0, 0, 0, 0, 10, 0])
                }
            }
            store.updateStyleActive()
            let adapted = await store.runAuto(.auto)?.value ?? false
            check("✦ Auto adds what the user usually does", adapted && store.autoIsAdapted
                  && abs(photo.adjustments.exposure - min(plain.exposure + 0.5, 5)) < 1e-9 && photo.adjustments.vibrance == min(plain.vibrance + 10, 100)
                  && photo.adjustments.temperature == plain.temperature && photo.history.last?.label == "Auto",
                  String(format: "exposure %.2f -> %.2f, vibrance %.0f -> %.0f", plain.exposure, photo.adjustments.exposure, plain.vibrance, photo.adjustments.vibrance))
            store.undo()
            store.learnFromEdits = false
            let off = await store.runAuto(.auto)?.value ?? false
            check("with learning off, ✦ Auto is plain", off && !store.autoIsAdapted && photo.adjustments == plain)
            store.undo()
            UserDefaults.standard.set(userSetting, forKey: LibraryStore.learnFromEditsKey)
            store.resetAdjustments()
            store.mode = .library
        }

        // Move to Trash: files and sidecars go to the (fake) trash, references are dropped, the next photo is current.
        do {
            let fakeTrash = dir.appendingPathComponent("FakeTrash")
            try? fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
            let realTrash = LibraryStore.trashFile
            LibraryStore.trashFile = { url in
                try FileManager.default.moveItem(at: url, to: fakeTrash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            }
            defer { LibraryStore.trashFile = realTrash }

            store.source = .all
            store.filter = .all; store.minRating = 0; store.editsFilter = .any; store.hideRejected = false
            let list = store.visiblePhotos
            if list.count >= 4 {
                let doomed = list[1], keep = list[2]
                store.select(doomed)
                store.setFlag(.reject)
                store.edit { $0.exposure = 0.5 }
                store.flushSaves()
                let sidecar = LibraryStore.sidecarURL(for: doomed.url)
                let hadSidecar = fm.fileExists(atPath: sidecar.path)
                let historyFile = SidecarFiles.historyURL(for: doomed.url)
                let hadHistory = fm.fileExists(atPath: historyFile.path)
                if let c = store.catalog.collections.first { store.addToCollection(c.id, [doomed]) }
                let before = store.photos.count

                check("delete rejected finds the reject", store.rejectedInSource.map(\.url) == [doomed.url],
                      "\(store.rejectedInSource.count)")
                store.requestTrashRejected()
                check("trash asks first", store.trashRequest?.urls == [doomed.url] && fm.fileExists(atPath: doomed.url.path))
                let msg = store.trashRequest.map { TrashText.message($0, photos: store.photos) } ?? ""
                check("warning names the photo", msg.contains(doomed.url.lastPathComponent), msg)
                store.trashRequest = nil
                check("cancel keeps the file", fm.fileExists(atPath: doomed.url.path) && store.photos.count == before)

                let failed = store.moveToTrash([doomed.url])
                check("photo file moved to trash", failed.isEmpty && !fm.fileExists(atPath: doomed.url.path))
                check("sidecar moved too", hadSidecar && !fm.fileExists(atPath: sidecar.path), "had \(hadSidecar)")
                check("history file moved too", hadHistory && !fm.fileExists(atPath: historyFile.path), "had \(hadHistory)")
                check("removed from library and collections", store.photos.count == before - 1
                      && !store.catalog.collections.contains { $0.members.contains(doomed.ref) }
                      && store.catalog.fingerprints[doomed.ref.key] == nil)
                check("next photo becomes current", store.currentID == keep.url, store.currentID?.lastPathComponent ?? "nil")

                // Bulk: two at once, and it stays gone after a rescan and a reopen.
                let two = Array(store.visiblePhotos.suffix(2))
                store.moveToTrash(two.map(\.url))
                await reloaded(store)
                let reopened = LibraryStore(catalogURL: catalogURL, watch: false)
                await reloaded(reopened)
                let goneURLs = Set([doomed.url] + two.map(\.url))
                check("bulk trash survives rescan and reopen", store.photos.count == before - 3
                      && !reopened.photos.contains { goneURLs.contains($0.url) }, "\(reopened.photos.count)")
                let trashed = (try? fm.contentsOfDirectory(atPath: fakeTrash.path)) ?? []
                check("real Trash untouched by tests", trashed.count >= 4, "\(trashed.count) in fake trash")
            } else {
                check("enough photos for trash test", false, "\(list.count)")
            }
        }

        // Brush: two separate strokes must both land in the mask.
        var brush = Mask(name: "Brush", kind: .brush)
        brush.strokes = [BrushStroke(points: [NormPoint(x: 0.2, y: 0.3), NormPoint(x: 0.25, y: 0.3)], radius: 0.03, feather: 0.3)]
        brush.strokes.append(BrushStroke(points: [NormPoint(x: 0.75, y: 0.7)], radius: 0.03, feather: 0.3))
        let size = CGSize(width: 1500, height: 1000)
        if let m = MaskRenderer.image(for: brush, size: size, url: a, base: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size))) {
            let s1 = SelfTest.sample(m, 0.22, 0.3), s2 = SelfTest.sample(m, 0.75, 0.7), off = SelfTest.sample(m, 0.5, 0.5)
            check("brush: first stroke painted", s1.g > 0.8, "\(s1)")
            check("brush: second stroke painted", s2.g > 0.8, "\(s2)")
            check("brush: unpainted area clear", off.g < 0.05, "\(off)")
        } else {
            check("brush mask renders", false)
        }
        // Sorting (restores the user's choice afterwards: it's remembered in UserDefaults).
        let (savedSort, savedDesc) = (store.sortOrder, store.sortDescending)
        store.source = .all; store.filter = .all; store.minRating = 0
        store.sortOrder = .fileName; store.sortDescending = false
        let names = store.visiblePhotos.map(\.name)
        check("sort by file name", names == names.sorted { $0.lowercased().compare($1.lowercased(), options: .numeric) == .orderedAscending }, "\(names)")
        store.sortDescending = true
        check("reverse order", store.visiblePhotos.map(\.name) == names.reversed(), "")
        if let first = store.visiblePhotos.last { store.select(first); store.setRating(5) }
        store.sortOrder = .rating; store.sortDescending = false
        check("sort by rating puts the best first", store.visiblePhotos.first?.rating == 5, "")
        store.sortOrder = savedSort; store.sortDescending = savedDesc

        await commandLineChecks(dir: dir.appendingPathComponent("cli"), check: check)
        await syncChecks(dir: dir.appendingPathComponent("sync"), check: check)
        await sidecarChecks(dir: dir.appendingPathComponent("sidecars"), check: check)
        await scaleChecks(dir: dir.appendingPathComponent("scale"), check: check)
        toleranceChecks(dir: dir.appendingPathComponent("tolerance"), check: check)
        await saveFailureChecks(dir: dir.appendingPathComponent("save-failures"), check: check)
        print(ok ? "LIBRARY PASSED" : "LIBRARY FAILED")
        return ok
    }
}

// MARK: - Sidecar files

extension LibraryTest {
    /// History lives in its own file with strokes pooled; older inline-history sidecars still load.
    @MainActor
    static func sidecarChecks(dir: URL, check: (String, Bool, String) -> Void) async {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("brushy.jpg")
        if let img = SelfTest.scene(width: 300, height: 200, hue: 0.5, variant: 1) { SelfTest.write(img, to: photo) }

        // A brush-heavy history: 60 steps, each adding a 150-point stroke to the same mask.
        var a = Adjustments()
        var mask = Mask(name: "Brush", kind: .brush)
        mask.local.exposure = 0.5
        var history = [HistoryStep(label: "Original", adjustments: a)]
        for i in 0..<60 {
            let y = Double(i) / 60
            mask.strokes.append(BrushStroke(points: (0..<150).map { NormPoint(x: Double($0) / 150, y: y + 0.01 * sin(Double($0))) }, radius: 0.03))
            a.masks = [mask]
            history.append(HistoryStep(label: "Brush \(i)", adjustments: a))
        }
        var sidecar = Sidecar()
        sidecar.rating = 3
        sidecar.adjustments = a
        sidecar.history = history
        sidecar.historyIndex = history.count - 1

        _ = try? SidecarFiles.write(sidecar, for: photo, history: true)
        let back = SidecarFiles.read(for: photo)
        check("history round-trips", back?.history == history && back?.historyIndex == history.count - 1 && back?.rating == 3, "")
        let mainSize = (try? fm.attributesOfItem(atPath: SidecarFiles.mainURL(for: photo).path)[.size] as? Int) ?? 0
        let histSize = (try? fm.attributesOfItem(atPath: SidecarFiles.historyURL(for: photo).path)[.size] as? Int) ?? 0
        let oldSize = (try? JSONEncoder().encode(sidecar).count) ?? 0
        check("pooled history is small", histSize > 0 && histSize * 10 < oldSize, "\(histSize / 1024) KB vs \(oldSize / 1024) KB inline")
        let mainJSON = (try? String(contentsOf: SidecarFiles.mainURL(for: photo), encoding: .utf8)) ?? ""
        check("main sidecar has no history", !mainJSON.contains("\"history\""), "\(mainSize / 1024) KB")

        // A rating change doesn't rewrite the history file.
        var rated = sidecar
        rated.rating = 5
        rated.history = Array(history.prefix(2))
        _ = try? SidecarFiles.write(rated, for: photo, history: false)
        let afterRating = SidecarFiles.read(for: photo)
        check("rating save leaves history alone", afterRating?.rating == 5 && afterRating?.history.count == history.count, "")

        // An older sidecar (history inline) loads, and moves its history out on the next save.
        let legacy = dir.appendingPathComponent("legacy.jpg")
        try? fm.copyItem(at: photo, to: legacy)
        let encoder = JSONEncoder()
        try? encoder.encode(sidecar).write(to: SidecarFiles.mainURL(for: legacy))
        let legacyBack = SidecarFiles.read(for: legacy)
        check("older inline-history sidecar loads", legacyBack?.history == history, "")
        if var lb = legacyBack {
            lb.rating = 1
            _ = try? SidecarFiles.write(lb, for: legacy, history: false)
            let migrated = SidecarFiles.read(for: legacy)
            check("older history moves to its own file", fm.fileExists(atPath: SidecarFiles.historyURL(for: legacy).path)
                  && migrated?.history == history && migrated?.rating == 1, "")
        }

        // Renames carry both files.
        let (done, errors) = LibraryStore.applyRenames(["brushy.jpg": "renamed.jpg"], in: dir.path)
        let renamed = dir.appendingPathComponent("renamed.jpg")
        check("rename moves both sidecar files", done.count == 1 && errors.isEmpty
              && fm.fileExists(atPath: SidecarFiles.historyURL(for: renamed).path)
              && !fm.fileExists(atPath: SidecarFiles.historyURL(for: photo).path)
              && SidecarFiles.read(for: renamed)?.history.count == history.count, "")

        // Nothing left to keep: both files go.
        _ = try? SidecarFiles.write(Sidecar(), for: renamed, history: true)
        check("empty sidecar removes both files", !fm.fileExists(atPath: SidecarFiles.mainURL(for: renamed).path)
              && !fm.fileExists(atPath: SidecarFiles.historyURL(for: renamed).path), "")

        // Sidecars saved under the app's old name move to the new folder when first read.
        let oldFolder = dir.appendingPathComponent("old-name", isDirectory: true)
        let oldSidecars = oldFolder.appendingPathComponent(LegacyNames.sidecarFolder, isDirectory: true)
        try? fm.createDirectory(at: oldSidecars, withIntermediateDirectories: true)
        var oldSidecar = Sidecar()
        oldSidecar.rating = 4
        try? JSONEncoder().encode(oldSidecar).write(to: oldSidecars.appendingPathComponent("old.jpg.json"))
        let oldBack = SidecarFiles.read(for: oldFolder.appendingPathComponent("old.jpg"))
        check("old-name sidecar folder is moved and read", oldBack?.rating == 4
              && !fm.fileExists(atPath: oldSidecars.path)
              && fm.fileExists(atPath: oldFolder.appendingPathComponent(SidecarFiles.folderName).path), "")
    }
}

// MARK: - Library scale

extension LibraryTest {
    /// Thumbnails survive a restart on disk; a change in one folder rescans only that folder.
    @MainActor
    static func scaleChecks(dir: URL, check: (String, Bool, String) -> Void) async {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let x = dir.appendingPathComponent("X"), y = dir.appendingPathComponent("Y")
        try? fm.createDirectory(at: x, withIntermediateDirectories: true)
        try? fm.createDirectory(at: y, withIntermediateDirectories: true)
        for (i, folder) in [x, x, y].enumerated() {
            if let img = SelfTest.scene(width: 900, height: 600, hue: Double(i) / 4, variant: i) {
                SelfTest.write(img, to: folder.appendingPathComponent("P\(i).jpg"))
            }
        }

        // Disk thumbnails: a fresh service (empty memory caches) reads what an earlier one wrote.
        let photo = x.appendingPathComponent("P0.jpg")
        var edit = Adjustments(); edit.exposure = 0.5
        let first = await ThumbnailService().image(url: photo, adjustments: edit)
        ThumbnailDiskCache.shared.flush()
        let files = (fm.enumerator(at: ThumbnailDiskCache.directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jpg" }
        check("thumbnails are written to disk", files.count >= 2, "\(files.count) files")
        let key = ThumbnailDiskCache.shared.key(url: photo, adjustments: edit)
        let fromDisk = key.flatMap { ThumbnailDiskCache.shared.load($0) }
        let second = await ThumbnailService().image(url: photo, adjustments: edit)
        check("thumbnails load back from disk", fromDisk != nil && second?.width == first?.width, "\(first?.width ?? 0) / \(second?.width ?? 0)")
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: photo.path)
        check("a changed file gets a new thumbnail", ThumbnailDiskCache.shared.key(url: photo, adjustments: edit) != key, "")

        // Per-folder rescans.
        let store = LibraryStore(catalogURL: dir.appendingPathComponent("catalog.json"), watch: false)
        store.catalog.folders = [CatalogFolder(path: x.path), CatalogFolder(path: y.path)]
        await withCheckedContinuation { c in store.reload { c.resume() } }
        let xID = store.catalog.folders[0].id, yID = store.catalog.folders[1].id
        let yPhoto = store.photos.first { $0.ref.folder == yID }
        check("folder events map to their folder", store.foldersContaining([x.appendingPathComponent("P9.jpg").path]) == [xID]
              && store.foldersContaining(["/somewhere/else.jpg"]) == nil, "")
        if let img = SelfTest.scene(width: 300, height: 200, hue: 0.7, variant: 3) { SelfTest.write(img, to: x.appendingPathComponent("P9.jpg")) }
        await withCheckedContinuation { c in store.reload(only: [xID]) { c.resume() } }
        check("rescanning one folder picks up its new photo", store.photos.count == 4
              && store.photos.contains { $0.url.lastPathComponent == "P9.jpg" }, "\(store.photos.count)")
        check("other folders are left as they were", store.photos.first { $0.ref.folder == yID } === yPhoto
              && store.photos.last?.ref.folder == yID, "")
    }
}

// MARK: - Damaged and hostile files

extension LibraryTest {
    /// Files written by other versions, damaged, or crafted to cause harm.
    static func toleranceChecks(dir: URL, check: (String, Bool, String) -> Void) {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func backups(_ prefix: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix + ".partial-") }
        }

        // Catalog: one folder from another version (no `excluded`), one with no path, and a
        // collection with one malformed member. Only the broken pieces may be dropped.
        let keep = UUID().uuidString
        let catalogJSON = """
        {"version":1,"folders":[
          {"id":"\(UUID().uuidString)","path":"/x/2024","includeSubfolders":true,"excluded":[],"addedAt":"2024-01-01T00:00:00Z"},
          {"id":"\(keep)","path":"/x/2025","includeSubfolders":false,"addedAt":"2025-01-01T00:00:00Z"},
          {"id":"\(UUID().uuidString)","includeSubfolders":true}],
         "collections":[{"id":"\(UUID().uuidString)","name":"Best","members":[],"createdAt":"2024-01-01T00:00:00Z"},
                        {"id":"\(UUID().uuidString)","name":"Mixed","members":[{"folder":"\(keep)","path":5},{"folder":"\(keep)","path":"a.jpg"}]}],
         "fingerprints":{"a":"1","b":7},
         "lastImport":{"folder":"\(keep)","refs":[{"folder":"\(keep)","path":"a.jpg"}]}}
        """
        let catalogURL = dir.appendingPathComponent("catalog.json")
        try? catalogJSON.write(to: catalogURL, atomically: true, encoding: .utf8)
        let catalog = Catalog.load(from: catalogURL)
        check("catalog keeps good folders when one is bad", catalog.folders.map(\.path) == ["/x/2024", "/x/2025"]
              && catalog.folders[1].includeSubfolders == false, "\(catalog.folders.map(\.path))")
        check("catalog keeps a collection with a bad member", catalog.collections.count == 2
              && catalog.collections[1].members.map(\.path) == ["a.jpg"], "\(catalog.collections.map(\.members.count))")
        check("catalog keeps other entries", catalog.fingerprints == ["a": "1"] && catalog.lastImport?.refs.count == 1, "")
        check("catalog with dropped entries is backed up", backups("catalog").count == 1, "\(backups("catalog"))")
        _ = Catalog.load(from: catalogURL)
        check("backup isn't repeated on every load", backups("catalog").count == 1, "")

        let current = dir.appendingPathComponent("current.json")
        try? Catalog().save(to: current)
        _ = Catalog.load(from: current)
        check("a clean catalog makes no backup", backups("current").isEmpty, "")

        // Presets: one malformed preset must not take the others with it.
        let presetsURL = dir.appendingPathComponent("presets.json")
        let presetsJSON = """
        [{"id":"\(UUID().uuidString)","name":"Warm","adjustments":{"temperature":20}},
         {"id":"\(UUID().uuidString)","name":"Broken","adjustments":7},
         {"name":"Older","adjustments":{"exposure":0.5,"futureField":1}}]
        """
        try? presetsJSON.write(to: presetsURL, atomically: true, encoding: .utf8)
        let presets = LibraryStore.loadPresets(from: presetsURL)
        check("presets keep good entries when one is bad", presets.map(\.name) == ["Warm", "Older"]
              && presets[1].adjustments.exposure == 0.5, "\(presets.map(\.name))")
        check("presets with dropped entries are backed up", backups("presets").count == 1, "")

        sidecarToleranceChecks(dir: dir.appendingPathComponent("sidecars"), check: check)

        // Values that would hang or blank the renderer are brought into range when loaded.
        let hostile = """
        {"masks":[{"name":"m","kind":"sky","grow":1e6,"softness":1e6,"radiusX":1e9,"feather":-3,
                   "strokes":[{"points":[{"x":0,"y":0},{"x":1e8,"y":-1e8}],"radius":0,"feather":7,"flow":-1}],
                   "shapes":[{"kind":"radial","radiusX":1e9,"radiusY":-5,"center":{"x":1e300,"y":0.5}}]}],
         "crop":{"rect":{"x":-2,"y":0.5,"width":-1,"height":9},"angle":1e5}}
        """
        let h = try? JSONDecoder().decode(Adjustments.self, from: Data(hostile.utf8))
        let hm = h?.masks.first, hs = hm?.strokes.first, shape = hm?.shapes.first
        check("hostile stroke values are clamped on load", hs?.points.last == NormPoint(x: 50, y: -50) && hs?.radius == 0.0005
              && hs?.feather == 1 && hs?.flow == 0, "\(String(describing: hs))")
        check("hostile mask values are clamped on load", hm?.grow == 100 && hm?.softness == 100 && hm?.radiusX == 10 && hm?.feather == 0
              && shape?.radiusX == 10 && shape?.radiusY == 0.001 && shape?.center.x == 50, "")
        let hc = h?.crop
        check("hostile crop is clamped on load", hc?.angle == 45 && hc?.rect.x == 0 && hc?.rect.width == EditLimits.minCropSide
              && hc?.rect.y == 0.5 && hc?.rect.height == 0.5, "\(String(describing: hc))")
        var normal = Adjustments()
        var nm = Mask(name: "n", kind: .brush)
        nm.strokes = [BrushStroke(points: [NormPoint(x: -0.3, y: 0.2), NormPoint(x: 1.4, y: 0.9)], radius: 0.25, feather: 0, flow: 0.5)]
        nm.radiusX = 3
        normal.masks = [nm]
        normal.crop.rect = NormRect(x: 0.1, y: 0.2, width: 0.9, height: 0.5)
        normal.crop.angle = -12
        let normalBack = (try? JSONEncoder().encode(normal)).flatMap { try? JSONDecoder().decode(Adjustments.self, from: $0) }
        check("edits the editor makes load unchanged", normalBack == normal, "")

        symlinkChecks(dir: dir.appendingPathComponent("links"), check: check)

        // Rename names can't hide files, add line breaks, disguise names or run too long.
        func renamed(_ custom: String) -> String {
            RenamePattern.plan([(path: "sub/IMG_1.jpg", date: Date(timeIntervalSince1970: 0))], pattern: .nameSequence,
                               customName: custom)["sub/IMG_1.jpg"] ?? ""
        }
        check("rename: leading dot doesn't hide files", renamed(".hidden") == "sub/hidden-001.jpg", renamed(".hidden"))
        check("rename: dot-dot stays a name", !renamed("..").contains("/../") && renamed("..").hasPrefix("sub/"), renamed(".."))
        check("rename: no control or direction characters", renamed("a\nb\u{0}c") == "sub/abc-001.jpg"
              && renamed("\u{202E}gpj.exe") == "sub/gpj.exe-001.jpg", renamed("a\nb\u{0}c"))
        check("rename: separators and colons replaced", renamed("a/b:c d") == "sub/a-b-c-d-001.jpg", renamed("a/b:c d"))
        let long = renamed(String(repeating: "é", count: 300))
        check("rename: long names are capped", (long as NSString).lastPathComponent.utf8.count < 255, "\(long.utf8.count) bytes")
        check("rename: ordinary names are unchanged", renamed("japan-2024") == "sub/japan-2024-001.jpg", "")

        // Renames: only swaps use temporary names, and an interrupted rename is put back on the next scan.
        let swap = dir.appendingPathComponent("swap")
        try? fm.createDirectory(at: swap, withIntermediateDirectories: true)
        for n in ["a.jpg", "b.jpg", "c.jpg", "CASE.jpg"] { try? Data(n.utf8).write(to: swap.appendingPathComponent(n)) }
        let (swapped, swapErrors) = LibraryStore.applyRenames(["a.jpg": "b.jpg", "b.jpg": "a.jpg", "c.jpg": "d.jpg", "CASE.jpg": "case.jpg"], in: swap.path)
        let contents = { ((try? fm.contentsOfDirectory(atPath: swap.path)) ?? []).sorted() }
        check("rename: swaps, plain and case-only renames all land", swapped.count == 4 && swapErrors.isEmpty
              && (try? String(contentsOf: swap.appendingPathComponent("b.jpg"), encoding: .utf8)) == "a.jpg"
              && (try? String(contentsOf: swap.appendingPathComponent("a.jpg"), encoding: .utf8)) == "b.jpg"
              && contents() == ["a.jpg", "b.jpg", "case.jpg", "d.jpg"], "\(contents()) \(swapErrors)")
        let leftover = LibraryFiles.temporaryRenameName(for: "IMG_7.CR3")
        check("rename: temporary names stay visible photos", !leftover.hasPrefix(".") && leftover.hasSuffix(".CR3")
              && LibraryFiles.originalName(fromTemporary: leftover) == "IMG_7.CR3", leftover)
        try? Data("x".utf8).write(to: swap.appendingPathComponent(leftover))
        let blocked = LibraryFiles.temporaryRenameName(for: "a.jpg")
        try? Data("y".utf8).write(to: swap.appendingPathComponent(blocked))
        let restored = LibraryFiles.recoverInterruptedRenames(in: swap, recursive: true)
        check("rename: an interrupted rename is put back on the next scan", restored == 1
              && fm.fileExists(atPath: swap.appendingPathComponent("IMG_7.CR3").path)
              && fm.fileExists(atPath: swap.appendingPathComponent(blocked).path)
              && (try? String(contentsOf: swap.appendingPathComponent("a.jpg"), encoding: .utf8)) == "b.jpg", "\(contents())")

        // Test output folders: only new, empty or marked ones are used.
        let outputs = dir.appendingPathComponent("outputs")
        try? fm.createDirectory(at: outputs.appendingPathComponent("full"), withIntermediateDirectories: true)
        try? "keep".write(to: outputs.appendingPathComponent("full/notes.txt"), atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: outputs.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: outputs.appendingPathComponent("link"), withDestinationURL: outputs.appendingPathComponent("empty"))
        let home = fm.homeDirectoryForCurrentUser
        check("test output: home folder is refused", !TestOutput.claim(home)
              && LibraryFiles.kind(home.appendingPathComponent(TestOutput.marker)) == nil, "")
        check("test output: a folder with other files is refused", !TestOutput.claim(outputs.appendingPathComponent("full"))
              && (try? fm.contentsOfDirectory(atPath: outputs.appendingPathComponent("full").path)) == ["notes.txt"], "")
        check("test output: a link is refused", !TestOutput.claim(outputs.appendingPathComponent("link")), "")
        check("test output: new and empty folders are used, then reused",
              TestOutput.claim(outputs.appendingPathComponent("new")) && TestOutput.claim(outputs.appendingPathComponent("empty"))
              && TestOutput.claim(outputs.appendingPathComponent("empty")), "")

        // Export checks the declared size before decoding (limit lowered so a normal photo trips it;
        // the real case is a tiny PNG declaring gigapixels).
        let big = dir.appendingPathComponent("big.jpg")
        if let img = SelfTest.scene(width: 600, height: 400, hue: 0.3, variant: 1) { SelfTest.write(img, to: big) }
        let limit = ImageSource.maxFullSizePixels
        ImageSource.maxFullSizePixels = 100_000
        var exportError = ""
        do { _ = try Exporter.export((big, Adjustments()), settings: ExportSettings(), to: dir) } catch { exportError = error.localizedDescription }
        check("export refuses an image over the pixel limit", exportError.contains("too large to export"), exportError)
        check("full-size decode refuses it; previews still load", ImageSource(url: big, maxPixelSize: nil) == nil
              && ImageSource(url: big, maxPixelSize: 256) != nil, "")
        ImageSource.maxFullSizePixels = limit
        let exported = try? Exporter.export((big, Adjustments()), settings: ExportSettings(), to: dir)
        check("export works under the limit", exported.map { fm.fileExists(atPath: $0.path) } == true, "")
    }

    /// A sidecar folder or file that's a link (planted in a shared or downloaded folder) is never
    /// followed: nothing outside the photo's folder is read, written, deleted or moved.
    static func symlinkChecks(dir: URL, check: (String, Bool, String) -> Void) {
        let fm = FileManager.default
        let victim = dir.appendingPathComponent("victim")
        try? fm.createDirectory(at: victim, withIntermediateDirectories: true)
        let precious = victim.appendingPathComponent("IMG_1.jpg.history.json")
        try? "precious".write(to: precious, atomically: true, encoding: .utf8)
        try? "{\"rating\":5}".write(to: victim.appendingPathComponent("IMG_1.jpg.json"), atomically: true, encoding: .utf8)
        func victimFiles() -> [String] { ((try? fm.contentsOfDirectory(atPath: victim.path)) ?? []).sorted() }
        let untouched = victimFiles()

        func sharedPhoto(_ linkName: String) -> URL {
            let shared = dir.appendingPathComponent("shared" + linkName)
            try? fm.createDirectory(at: shared, withIntermediateDirectories: true)
            try? fm.createSymbolicLink(at: shared.appendingPathComponent(linkName), withDestinationURL: victim)
            let photo = shared.appendingPathComponent("IMG_1.jpg")
            if let img = SelfTest.scene(width: 64, height: 64, hue: 0.1, variant: 0) { SelfTest.write(img, to: photo) }
            return photo
        }

        // The sidecar folder itself is a link: everything through it is refused.
        let photo1 = sharedPhoto(SidecarFiles.folderName)
        check("sidecar folder link: not read through", SidecarFiles.read(for: photo1) == nil, "")
        var s = Sidecar(); s.rating = 3
        let wrote = (try? SidecarFiles.write(s, for: photo1, history: true)) != nil
        check("sidecar folder link: write is refused", !wrote && victimFiles() == untouched, "\(victimFiles())")
        s.rating = 0
        let removed = (try? SidecarFiles.write(s, for: photo1, history: true)) != nil
        check("sidecar folder link: delete is refused", !removed && victimFiles() == untouched
              && (try? String(contentsOf: precious, encoding: .utf8)) == "precious", "")
        check("sidecar folder link: trash skips its sidecars", SidecarFiles.all(for: photo1).allSatisfy { !SidecarFiles.isSafe($0, for: photo1) }, "")
        let (moved1, _) = LibraryStore.applyRenames(["IMG_1.jpg": "renamed.jpg"], in: photo1.deletingLastPathComponent().path)
        check("sidecar folder link: rename moves the photo, not files through the link", moved1.count == 1 && victimFiles() == untouched, "")

        // The old-name folder is a link: it isn't migrated, and edits go to a new real folder.
        let photo2 = sharedPhoto(LegacyNames.sidecarFolder)
        check("old-name folder link: not read through", SidecarFiles.read(for: photo2) == nil, "")
        s.rating = 3
        let wrote2 = (try? SidecarFiles.write(s, for: photo2, history: true)) != nil
        let newFolder = photo2.deletingLastPathComponent().appendingPathComponent(SidecarFiles.folderName)
        check("old-name folder link: edits saved in a real folder instead", wrote2 && LibraryFiles.kind(newFolder) == .directory
              && SidecarFiles.read(for: photo2)?.rating == 3 && victimFiles() == untouched, "")

        // A link in place of one sidecar file inside a real sidecar folder.
        let real = dir.appendingPathComponent("real")
        try? fm.createDirectory(at: real.appendingPathComponent(SidecarFiles.folderName), withIntermediateDirectories: true)
        let photo = real.appendingPathComponent("IMG_1.jpg")
        if let img = SelfTest.scene(width: 64, height: 64, hue: 0.1, variant: 0) { SelfTest.write(img, to: photo) }
        try? fm.createSymbolicLink(at: SidecarFiles.historyURL(for: photo), withDestinationURL: precious)
        s.rating = 2
        let wrote3 = (try? SidecarFiles.write(s, for: photo, history: true)) != nil
        check("linked sidecar file: write is refused", !wrote3 && (try? String(contentsOf: precious, encoding: .utf8)) == "precious", "")

        // Rename records come from the catalog file: they can't move photos out of their folder.
        let outside = dir.appendingPathComponent("outside")
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let (done, errors) = LibraryStore.applyRenames(["IMG_1.jpg": "../outside/IMG_1.jpg"], in: real.path)
        try? fm.createSymbolicLink(at: real.appendingPathComponent("escape"), withDestinationURL: outside)
        let (viaLink, linkErrors) = LibraryStore.applyRenames(["IMG_1.jpg": "escape/IMG_1.jpg"], in: real.path)
        check("rename can't move a photo through a linked subfolder", viaLink.isEmpty && linkErrors.count == 1
              && fm.fileExists(atPath: photo.path), "\(linkErrors)")
        check("rename can't move a photo out of its folder", done.isEmpty && errors.count == 1
              && fm.fileExists(atPath: photo.path) && !fm.fileExists(atPath: outside.appendingPathComponent("IMG_1.jpg").path), "\(errors)")
    }

    /// One malformed item in a sidecar loses only that item, and the original is kept.
    static func sidecarToleranceChecks(dir: URL, check: (String, Bool, String) -> Void) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent(SidecarFiles.folderName), withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("p.jpg")
        if let img = SelfTest.scene(width: 64, height: 64, hue: 0.2, variant: 0) { SelfTest.write(img, to: photo) }
        func backups() -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(SidecarFiles.folderName).path)) ?? [])
                .filter { $0.contains(".partial-") }
        }

        // A stroke and a crop from another version (missing fields), a snapshot with no
        // adjustments, a malformed curve point and a shape of an unknown kind.
        let main = """
        {"version":2,"rating":5,"flag":"pick",
         "snapshots":[{"id":"\(UUID().uuidString)","name":"Final","date":0,"adjustments":{}},{"name":"x"}],
         "adjustments":{"exposure":1.2,"crop":{"rect":{"x":0.1,"y":0,"width":0.8,"height":1},"angle":2},
           "masks":[{"name":"Sky","kind":"brush","strokes":[
             {"points":[{"x":0.1,"y":0.1}],"radius":0.05,"feather":0.5,"flow":1,"erase":false},
             {"points":[{"x":0.2,"y":0.2},{"x":"bad"}],"radius":0.05,"feather":0.5,"flow":1}],
             "shapes":[{"kind":"radial","mode":"subtract"},{"kind":"polygon"}]}],
           "curve":[{"x":0,"y":0},{"x":0.5,"y":0.7},{"x":1}]}}
        """
        try? main.write(to: SidecarFiles.mainURL(for: photo), atomically: true, encoding: .utf8)
        let s = SidecarFiles.read(for: photo)
        let mask = s?.adjustments.masks.first
        check("sidecar keeps good strokes when one is from another version", mask?.strokes.count == 2
              && mask?.strokes[1].points.count == 1 && mask?.strokes[1].erase == false, "\(mask?.strokes.count ?? -1) of 2")
        check("sidecar keeps good shapes", mask?.shapes.map(\.mode) == [.subtract], "")
        check("sidecar keeps good curve points", s?.adjustments.curve == [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7)], "")
        check("sidecar keeps good snapshots", s?.snapshots.map(\.name) == ["Final"], "")
        check("crop with a missing field still loads", s?.adjustments.crop.rect.x == 0.1 && s?.adjustments.crop.angle == 2, "")
        check("sidecar keeps the rest", s?.rating == 5 && s?.flag == .pick && s?.adjustments.exposure == 1.2, "")
        check("sidecar with dropped items is backed up", backups().count == 1, "\(backups())")

        // History file: one bad step and one bad pooled stroke.
        var a = Adjustments(); a.exposure = 0.3
        var m = Mask(name: "B", kind: .brush)
        m.strokes = [BrushStroke(points: [NormPoint(x: 0.5, y: 0.5)])]
        a.masks = [m]
        let history = [HistoryStep(label: "Original", adjustments: Adjustments()), HistoryStep(label: "Brush", adjustments: a)]
        let file = HistoryFile(history, index: 1)
        guard let data = try? JSONEncoder().encode(file),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var steps = json["steps"] as? [Any], var pool = json["strokes"] as? [String: Any] else {
            check("history fixture builds", false, ""); return
        }
        steps.insert(["label": "Broken"], at: 1)
        pool["junk"] = 5
        json["steps"] = steps; json["strokes"] = pool
        try? JSONSerialization.data(withJSONObject: json).write(to: SidecarFiles.historyURL(for: photo))
        let h = SidecarFiles.read(for: photo)
        check("history keeps good steps and strokes", h?.history.map(\.label) == ["Original", "Brush"]
              && h?.history.last?.adjustments.masks.first?.strokes.count == 1, "\(h?.history.map(\.label) ?? [])")
        check("history with dropped items is backed up", backups().count == 2, "\(backups())")

        // A sidecar written by this version loads without a backup.
        let clean = dir.appendingPathComponent("clean.jpg")
        try? fm.copyItem(at: photo, to: clean)
        var good = Sidecar(); good.rating = 2; good.adjustments = a
        good.history = history; good.historyIndex = 1
        _ = try? SidecarFiles.write(good, for: clean, history: true)
        let cleanBack = SidecarFiles.read(for: clean)
        check("a clean sidecar round-trips without a backup", cleanBack?.adjustments == a && cleanBack?.history == history
              && backups().count == 2, "")
    }
}

// MARK: - Save failures

extension LibraryTest {
    /// A folder that can't be written to: the photo stays unsaved with a reason, and saves once it can.
    @MainActor
    static func saveFailureChecks(dir: URL, check: (String, Bool, String) -> Void) async {
        let fm = FileManager.default
        let locked = dir.appendingPathComponent("Locked")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        if let img = SelfTest.scene(width: 300, height: 200, hue: 0.4, variant: 2) { SelfTest.write(img, to: locked.appendingPathComponent("L1.jpg")) }
        let store = LibraryStore(catalogURL: dir.appendingPathComponent("catalog.json"), watch: false)
        store.catalog.folders = [CatalogFolder(path: LibraryFiles.canonical(locked))]
        await withCheckedContinuation { c in store.reload { c.resume() } }
        let scan = await store.scanForImport(locked, includeSubfolders: true)
        check("writable folder is reported writable", scan.writable, "")

        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let lockedScan = await store.scanForImport(locked, includeSubfolders: true)
        check("read-only folder is reported at import", !lockedScan.writable, "")
        guard let photo = store.photos.first else { check("save-failure photo loads", false, ""); return }
        photo.rating = 4
        store.scheduleSave(photo)
        store.flushSaves()
        let reason = store.failedSaves[photo.url] ?? ""
        check("a failed save keeps the photo unsaved", store.hasSaveProblems && reason.contains("read-only"), reason)
        check("the warning names the folder", store.saveProblems.first?.title == "Locked" && store.saveProblems.first?.photoCount == 1, "")
        check("a failed save doesn't claim to be saved", store.lastSaved == nil && SidecarFiles.read(for: photo.url) == nil, "")

        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        store.flushSaves()
        check("saves once the folder can be written", !store.hasSaveProblems && SidecarFiles.read(for: photo.url)?.rating == 4, "")

        check("disk full is described plainly",
              LibraryStore.describeSaveError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == "The disk is full", "")
    }
}
