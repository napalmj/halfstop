import Foundation
import CoreImage
import Metal
import QuartzCore

/// Editing-speed benchmark: `Halfstop --bench <dir> [--file <photo>]`.
///
/// Times what one live-preview frame costs while dragging a control: building the
/// develop graph on the main thread (`cpu`), and the whole frame until the GPU
/// finishes rendering it into a drawable-sized texture (`frame`). Medians of N frames.
@MainActor
enum Bench {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let d = args.firstIndex(of: "--lut-dump"), d + 1 < args.count {
            // Reference output for checking LUT changes are exact.
            var a = Adjustments()
            a.contrast = 30; a.whites = -20; a.blacks = 15; a.highlights = 25
            a.curve = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.4, y: 0.35), CurvePoint(x: 1, y: 0.95)]
            a.hsl[0].saturation = 40; a.hsl[3].hue = -30; a.hsl[5].luminance = 25; a.hsl[7].saturation = -60
            a.grading.shadows.saturation = 30; a.grading.highlights.saturation = 45; a.grading.midtones.luminance = 10; a.grading.balance = 20
            try? ColorLUT.cubeData(for: ColorLUTKey(a)).write(to: URL(fileURLWithPath: args[d + 1]))
            exit(0)
        }
        guard let i = args.firstIndex(of: "--bench"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("bench-24mp.jpg")
        if let f = args.firstIndex(of: "--file"), f + 1 < args.count {
            url = URL(fileURLWithPath: args[f + 1])
        } else if !FileManager.default.fileExists(atPath: url.path), let img = SelfTest.scene(width: 6000, height: 4000, hue: 0.58, variant: 0) {
            SelfTest.write(img, to: url)
        }
        run(url: url)
        exit(0)
    }

    /// A typical preview drawable on a Retina laptop (about 1100×730 pt).
    static let drawable = CGSize(width: 2200, height: 1460)
    static let frames = 30

    static func run(url: URL) {
        guard let src = ImageSource(url: url, maxPixelSize: PreviewRenderer.previewPixelSize) else {
            print("Could not load \(url.path)"); return
        }
        print("Bench: \(url.lastPathComponent)  source \(Int(src.size.width))×\(Int(src.size.height))  drawable \(Int(drawable.width))×\(Int(drawable.height))  \(frames) frames, medians")
        let tex = makeTexture()

        func scenario(_ name: String, histogram: Bool = false, _ make: (Int) -> Adjustments) {
            // Warm up (kernel compiles, caches).
            for w in 0..<3 { _ = frame(src, make(1000 + w), tex: tex, histogram: histogram) }
            var cpu: [Double] = [], total: [Double] = []
            for n in 0..<frames {
                let (c, t) = frame(src, make(n), tex: tex, histogram: histogram)
                cpu.append(c); total.append(t)
            }
            print("  " + name.padding(toLength: 34, withPad: " ", startingAt: 0) + String(format: "cpu %7.2f ms   frame %7.2f ms", median(cpu), median(total)))
        }

        scenario("exposure drag") { n in var a = Adjustments(); a.exposure = Double(n) * 0.02; return a }
        scenario("exposure drag + histogram", histogram: true) { n in var a = Adjustments(); a.exposure = Double(n) * 0.02; return a }
        scenario("heavy: hl/sh + NR + sharpen") { n in
            var a = Adjustments(); a.exposure = Double(n) * 0.02; a.highlights = -60; a.shadows = 50
            a.noiseReduction = 40; a.sharpening = 50; return a
        }
        scenario("HSL drag") { n in var a = Adjustments(); a.hsl[0].saturation = Double(n) - 15; a.hsl[5].hue = 20; return a }
        scenario("grading wheel drag") { n in
            var a = Adjustments(); a.grading.shadows.saturation = 30; a.grading.highlights.hue = Double(n * 7); a.grading.highlights.saturation = 40; return a
        }
        scenario("curve point drag") { n in
            var a = Adjustments(); a.curve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.4 + Double(n) * 0.005), CurvePoint(x: 1, y: 1)]; return a
        }

        scenario("channel + hue curve drag") { n in
            var a = Adjustments(); a.curveRed = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.45 + Double(n) * 0.004), CurvePoint(x: 1, y: 1)]
            HueCurves.setPoint(&a.hueCurves.saturation, x: 0.6, y: 0.3 + Double(n) * 0.005); return a
        }
        scenario("clarity drag") { n in var a = Adjustments(); a.clarity = Double(n * 2); return a }
        scenario("dehaze drag") { n in var a = Adjustments(); a.dehaze = Double(n * 2); return a }
        scenario("texture + clarity + dehaze + grain") { n in
            var a = Adjustments(); a.texture = 20; a.clarity = 25; a.dehaze = 20; a.grain.amount = 20 + Double(n); return a
        }
        var spots: [Spot] = []
        for i in 0..<20 {
            let x = 0.1 + Double(i % 5) * 0.18, y = 0.15 + Double(i / 5) * 0.2
            spots.append(Spot(center: NormPoint(x: x, y: y), source: NormPoint(x: x + 0.04, y: y)))
        }
        // Zoomed in to 100% on the full-resolution decode (what checking sharpness costs).
        if let full = ImageSource(url: url, maxPixelSize: nil) {
            let fit = PreviewLayout.fit(full.size, in: CGSize(width: drawable.width / 2, height: drawable.height / 2))
            var zoom = PreviewZoom()
            zoom.scale = max(full.size.width / (fit.width * 2), 1.01)
            zoom.focus = CGPoint(x: 0.4, y: 0.45)
            for w in 0..<3 { _ = frame(full, { var a = Adjustments(); a.exposure = Double(w) * 0.1; return a }(), tex: tex, histogram: false, zoom: zoom) }
            func zoomed(_ name: String, _ make: (Int) -> Adjustments) {
                var cpu: [Double] = [], total: [Double] = []
                for n in 0..<frames {
                    let (c, t) = frame(full, make(n), tex: tex, histogram: false, zoom: zoom)
                    cpu.append(c); total.append(t)
                }
                print("  " + name.padding(toLength: 34, withPad: " ", startingAt: 0) + String(format: "cpu %7.2f ms   frame %7.2f ms", median(cpu), median(total)))
            }
            zoomed("100% zoom, exposure drag") { n in var a = Adjustments(); a.exposure = Double(n) * 0.02; return a }
            zoomed("100% zoom, sharpen + NR drag") { n in
                var a = Adjustments(); a.sharpening = Double(20 + n); a.noiseReduction = 30; return a
            }
            var t = CACurrentMediaTime()
            _ = ImageSource(url: url, maxPixelSize: nil).map { frame($0, Adjustments(), tex: tex, histogram: false, zoom: zoom) }
            t = CACurrentMediaTime() - t
            print("  " + "100% zoom, first frame (decode)".padding(toLength: 34, withPad: " ", startingAt: 0) + String(format: "%7.0f ms", t * 1000))
        }
        scenario("5 removed spots, exposure drag") { n in
            var a = Adjustments(); a.exposure = Double(n) * 0.02; a.spots = Array(spots.prefix(5)); return a
        }
        scenario("20 removed spots, exposure drag") { n in
            var a = Adjustments(); a.exposure = Double(n) * 0.02; a.spots = spots; return a
        }
        scenario("20 removed spots, HSL drag") { n in
            var a = Adjustments(); a.hsl[0].saturation = Double(n) - 15; a.spots = spots; return a
        }

        // Brush: 20 earlier strokes, then one growing stroke (a point per frame).
        var mask = Mask(name: "Brush", kind: .brush)
        mask.local.exposure = 0.7
        for s in 0..<20 {
            let y = 0.1 + Double(s) * 0.04
            mask.strokes.append(BrushStroke(points: (0..<120).map { NormPoint(x: 0.1 + Double($0) * 0.006, y: y) }, radius: 0.03))
        }
        let baseMask = mask
        scenario("brush paint (20 strokes + live)") { n in
            var m = baseMask
            m.strokes.append(BrushStroke(points: (0...(n + 1)).map { NormPoint(x: 0.2 + Double($0) * 0.01, y: 0.5) }, radius: 0.03))
            var a = Adjustments(); a.masks = [m]; return a
        }

        benchAuto(url: url, preview: src)
        benchStore()
    }

    /// One-click auto adjustments, measured on the already-decoded preview source (as the buttons do).
    static func benchAuto(url: URL, preview src: ImageSource) {
        func time(_ name: String, runs: Int = 5, _ body: () -> Void) {
            body()   // warm up
            var t: [Double] = []
            for _ in 0..<runs { let t0 = CACurrentMediaTime(); body(); t.append((CACurrentMediaTime() - t0) * 1000) }
            print("  " + name.padding(toLength: 38, withPad: " ", startingAt: 0) + String(format: "%7.2f ms", median(t)))
        }
        let engine = AutoEngine.shared
        func request(_ kind: AutoKind) -> AutoRequest { AutoRequest(url: url, kind: kind, adjustments: Adjustments()) }
        // First use of a photo: decodes the small measurement copy.
        engine.clear(sources: true)
        let t0 = CACurrentMediaTime()
        _ = engine.resultNow(for: request(.tone))
        print("  " + "auto tone, first (incl. decode)".padding(toLength: 34, withPad: " ", startingAt: 0)
              + String(format: "%7.2f ms", (CACurrentMediaTime() - t0) * 1000))
        // The first face request of a session loads Vision's model (the editor warms it up on open).
        engine.clear()
        let tv = CACurrentMediaTime()
        _ = engine.resultNow(for: request(.auto))
        print("  " + "auto ✦ Auto, first Vision use".padding(toLength: 34, withPad: " ", startingAt: 0)
              + String(format: "%7.2f ms", (CACurrentMediaTime() - tv) * 1000))
        // Decoded, nothing cached: what a click costs on the photo being edited.
        for (kind, name) in [(AutoKind.whiteBalance, "WB"), (.tone, "tone"), (.auto, "✦ Auto"), (.straighten, "straighten")] {
            time("auto \(name) (background, uncached)") { engine.clear(); _ = engine.resultNow(for: request(kind)) }
        }
        time("auto ✦ Auto (cached)") { _ = engine.resultNow(for: request(.auto)) }
        // What it decided, to sanity-check real photos passed with --file.
        if let r = engine.resultNow(for: request(.auto)) {
            let a = r.applied(to: Adjustments())
            print("  ✦ Auto on this photo: " + (r.scene?.rawValue ?? "?") + String(format:
                ", temp %.0f tint %.0f, exposure %.2f, contrast %.0f, highlights %.0f, shadows %.0f, whites %.0f, blacks %.0f, vibrance %.0f, saturation %.0f",
                a.temperature, a.tint, a.exposure, a.contrast, a.highlights, a.shadows, a.whites, a.blacks, a.vibrance, a.saturation))
            print("    faces \(r.hints.faces.count), second opinion \(r.opinion.map { String(describing: $0) } ?? "none")")
        }
        if let s = engine.resultNow(for: request(.straighten)) {
            print("  Auto straighten on this photo: " + (s.horizon.map { String(format: "horizon %.2f° (confidence %.2f)", $0.angle, $0.confidence) } ?? "no horizon")
                  + (s.angle.map { String(format: ", sets %.1f°", $0) } ?? ", leaves the angle"))
        }
    }

    /// One preview frame through the same code path the editor uses.
    static func frame(_ src: ImageSource, _ a: Adjustments, tex: MTLTexture, histogram: Bool,
                      zoom: PreviewZoom = PreviewZoom()) -> (Double, Double) {
        let t0 = CACurrentMediaTime()
        let img = PreviewRenderer.previewImage(src, a, geometry: .full, overlayMask: nil, drawableSize: drawable, scale: 2, zoom: zoom.scale)
        let t1 = CACurrentMediaTime()
        guard let cb = Render.commandQueue.makeCommandBuffer() else { return (0, 0) }
        let rect = PreviewMTKView.encode(img, drawableSize: drawable, scale: 2, background: CIColor(red: 0.09, green: 0.09, blue: 0.095),
                                         colorSpace: Render.displayP3, pixelFormat: .bgra8Unorm, commandBuffer: cb, texture: { tex },
                                         placement: { c, v in zoom.rect(content: c, in: v) })
        let readback = histogram ? rect.flatMap { HistogramReadback(source: tex, rect: $0, commandBuffer: cb) } : nil
        cb.commit()
        cb.waitUntilCompleted()
        if histogram, readback?.read() == nil { print("  (histogram readback failed)") }
        let t2 = CACurrentMediaTime()
        return ((t1 - t0) * 1000, (t2 - t0) * 1000)
    }

    static func makeTexture() -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(drawable.width), height: Int(drawable.height), mipmapped: false)
        desc.usage = [.shaderWrite, .renderTarget, .shaderRead]
        desc.storageMode = .private
        return Render.device.makeTexture(descriptor: desc)!
    }

    /// Library-size costs paid on every slider tick: finding the current photo, the visible list.
    static func benchStore() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("halfstop-bench-\(UUID().uuidString).json")
        let store = LibraryStore(catalogURL: tmp, watch: false)
        let folder = UUID()
        let photos = (0..<10_000).map { i in
            Photo(url: URL(fileURLWithPath: "/bench/photos/IMG_\(i).CR3"), ref: PhotoRef(folder: folder, path: "IMG_\(i).CR3"), sidecar: Sidecar())
        }
        store.photos = photos
        store.currentID = photos[photos.count - 1].url
        // About 40 sliders each read the current value once per tick.
        var t = CACurrentMediaTime()
        for _ in 0..<frames { for _ in 0..<40 { _ = store.value(\.exposure) } }
        let currentMs = (CACurrentMediaTime() - t) * 1000 / Double(frames)
        t = CACurrentMediaTime()
        for _ in 0..<frames { _ = store.visiblePhotos.count }
        let visibleMs = (CACurrentMediaTime() - t) * 1000 / Double(frames)
        print("  " + "10k photos: 40 slider reads".padding(toLength: 34, withPad: " ", startingAt: 0) + String(format: "%7.2f ms per tick", currentMs))
        print("  " + "10k photos: visiblePhotos".padding(toLength: 34, withPad: " ", startingAt: 0) + String(format: "%7.2f ms per access", visibleMs))
        try? FileManager.default.removeItem(at: tmp)

        // Learn from my edits: one ✦ Auto prediction over 5,000 edited photos.
        var model = StyleModel()
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for i in 0..<5000 {
            model.set("p\(i)", features: (0..<StyleFeatures.count).map { _ in rnd() }, delta: (0..<StyleSliders.count).map { _ in rnd() - 0.5 })
        }
        let query = (0..<StyleFeatures.count).map { _ in rnd() }
        t = CACurrentMediaTime()
        for _ in 0..<frames { _ = model.predict(query) }
        let knnMs = (CACurrentMediaTime() - t) * 1000 / Double(frames)
        print("  " + "learn: k-NN over 5k edited photos".padding(toLength: 34, withPad: " ", startingAt: 0) + String(format: "%7.2f ms per ✦ Auto", knnMs))
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
}
