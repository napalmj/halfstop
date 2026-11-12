import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Headless checks for the develop pipeline: `Pixon --selftest <output-dir>`.
/// Also `Pixon --make-samples <dir>` writes synthetic test photos.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--make-samples"), i + 1 < args.count {
            makeSamples(in: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            exit(run(dir: URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
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

        // LUT speed (rebuilt on every curve/HSL/wheel drag).
        let t0 = Date()
        var key = ColorLUTKey(Adjustments()); key.contrast = 13; key.hsl[2].hue = 20; key.grading.midtones.saturation = 30
        _ = ColorLUT.cubeData(for: key)
        let ms = Date().timeIntervalSince(t0) * 1000
        check("LUT builds fast", ms < 60, String(format: "%.1f ms", ms))

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

/// `Pixon --snapshot <dir>`: drives the UI through its main states and saves window captures.
/// The Metal preview is drawn separately (window caching can't read Metal layers).
@MainActor
enum Snapshot {
    static var outputDir: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func run(store: LibraryStore, renderer: PreviewRenderer) {
        guard let dir = outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            @MainActor func shot(_ name: String) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("no window"); return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                print("snapshot \(name)")
            }
            @MainActor func preview(_ name: String) {
                guard let p = store.current, let src = renderer.source(for: p.url) else { return }
                let img = src.developed(p.adjustments, geometry: store.activeMaskID != nil ? .none : .full,
                                        overlayMask: store.showMaskOverlay ? store.activeMaskID : nil)
                try? Render.background.writeJPEGRepresentation(of: img, to: dir.appendingPathComponent(name + ".jpg"),
                                                               colorSpace: Render.sRGB, options: [:])
            }
            await wait(2.5)
            store.setRating(4); store.setFlag(.pick)
            store.step(1); store.setFlag(.reject)
            store.step(1); store.setRating(2)
            await wait(1.5)
            shot("1-library")

            store.mode = .edit
            await wait(2.5)
            shot("2-edit-quick")

            store.checkpoint()
            store.edit { $0.exposure = 0.4; $0.contrast = 25; $0.temperature = 20; $0.vignette = -30 }
            store.panelTab = .detailed
            await wait(1.5)
            shot("3-edit-detailed")

            store.edit { $0.grading.shadows = GradeWheel(hue: 215, saturation: 45); $0.grading.highlights = GradeWheel(hue: 40, saturation: 35) }
            store.addMask(.radial)
            store.editMask { $0.center = NormPoint(x: 0.68, y: 0.22); $0.local.exposure = 0.8 }
            store.setOverlay(true)
            await wait(1.5)
            shot("4-mask-radial")
            preview("4-mask-radial-preview")

            store.setOverlay(false)
            store.activeMaskID = nil
            store.isCropping = true
            store.edit { $0.crop.angle = 4 }
            await wait(1.5)
            shot("5-crop")
            store.isCropping = false
            await wait(1)
            preview("6-final-preview")
            if let p = store.current, let src = renderer.source(for: p.url) {
                let img = src.developed(p.adjustments)
                let ok = PreviewMTKView.renderOffscreen(img, size: CGSize(width: 1200, height: 800),
                                                        to: dir.appendingPathComponent("7-metal-path.png"))
                print("metal path render \(ok)")
            }

            store.resetAdjustments()
            store.setRating(0)
            store.flushSaves()
            print("snapshot done")
            NSApp.terminate(nil)
        }
    }
}
