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

        benchStore()
    }

    /// One preview frame through the same code path the editor uses.
    static func frame(_ src: ImageSource, _ a: Adjustments, tex: MTLTexture, histogram: Bool) -> (Double, Double) {
        let t0 = CACurrentMediaTime()
        let img = PreviewRenderer.previewImage(src, a, geometry: .full, overlayMask: nil, drawableSize: drawable, scale: 2)
        let t1 = CACurrentMediaTime()
        guard let cb = Render.commandQueue.makeCommandBuffer() else { return (0, 0) }
        let rect = PreviewMTKView.encode(img, drawableSize: drawable, scale: 2, background: CIColor(red: 0.09, green: 0.09, blue: 0.095),
                                         colorSpace: Render.displayP3, pixelFormat: .bgra8Unorm, commandBuffer: cb, texture: { tex })
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
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
}
