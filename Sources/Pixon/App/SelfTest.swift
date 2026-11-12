import SwiftUI
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Metal

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
            let dir = URL(fileURLWithPath: args[i + 1])
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

/// `Pixon --snapshot <dir>`: drives the UI through its main states and saves window captures.
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

    static func run(store: LibraryStore, renderer: PreviewRenderer) {
        guard let dir = outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
                try? FileManager.default.removeItem(at: copy.appendingPathComponent(".pixon"))
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
        await sidecarChecks(dir: dir.appendingPathComponent("sidecars"), check: check)
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

        SidecarFiles.write(sidecar, for: photo, history: true)
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
        SidecarFiles.write(rated, for: photo, history: false)
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
            SidecarFiles.write(lb, for: legacy, history: false)
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
        SidecarFiles.write(Sidecar(), for: renamed, history: true)
        check("empty sidecar removes both files", !fm.fileExists(atPath: SidecarFiles.mainURL(for: renamed).path)
              && !fm.fileExists(atPath: SidecarFiles.historyURL(for: renamed).path), "")
    }
}
