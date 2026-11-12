// Draws Pixon's app icon with Core Graphics and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift [variant] [preview.png]
//
// variant: aperture (default) | wheel | landscape
// If a preview path is given, also writes a side-by-side sheet of all variants.
import AppKit
import CoreImage
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1] : "aperture"
let previewPath = args.count > 2 ? args[2] : nil
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}
func hsb(_ h: Double, _ s: Double, _ v: Double, _ a: Double = 1) -> CGColor {
    let c = NSColor(calibratedHue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: v, alpha: a).usingColorSpace(.sRGB)!
    return rgb(c.redComponent, c.greenComponent, c.blueComponent, a)
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

/// macOS icon grid: 1024 canvas, 824 body with ~185 corner radius, soft drop shadow.
func drawBody(_ ctx: CGContext, fill: (CGContext, CGRect) -> Void) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0.08, 0.08, 0.1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    fill(ctx, body)
    // Thin top highlight for a bit of glass.
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
}

/// Hue ring (or disc when inner is 0) from Core Image's color-wheel generator: smooth, no seams.
/// Saturation rises from the center outward, like a grading wheel.
let ciContext = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])
func hueRing(_ ctx: CGContext, center c: CGPoint, outer: CGFloat, inner: CGFloat, brightness: Double = 0.95) {
    let f = CIFilter(name: "CIHueSaturationValueGradient", parameters: [
        "inputValue": brightness, "inputRadius": outer, "inputSoftness": 0.5, "inputDither": 0,
        "inputColorSpace": sRGB,
    ])!
    guard let out = f.outputImage,
          out.extent.width.isFinite,
          let disc = ciContext.createCGImage(out, from: out.extent) else { return }
    let ring = CGMutablePath()
    ring.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
    if inner > 0 { ring.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2)) }
    ctx.saveGState()
    ctx.addPath(ring)
    ctx.clip(using: .evenOdd)
    ctx.draw(disc, in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
    ctx.restoreGState()
}

// MARK: - Variants

func aperture(_ ctx: CGContext) {
    drawBody(ctx) { ctx, body in
        ctx.drawLinearGradient(gradient([rgb(0.16, 0.16, 0.19), rgb(0.07, 0.07, 0.09)], [0, 1]),
                               start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        let c = CGPoint(x: 512, y: 512)
        // Soft colored glow behind the lens.
        ctx.drawRadialGradient(gradient([rgb(0.98, 0.55, 0.3, 0.35), rgb(0.6, 0.3, 0.9, 0)], [0, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: 400, options: [])
        // Color-wheel ring.
        hueRing(ctx, center: c, outer: 318, inner: 262)
        // Dark lens barrel.
        ctx.addEllipse(in: CGRect(x: c.x - 262, y: c.y - 262, width: 524, height: 524))
        ctx.setFillColor(rgb(0.06, 0.06, 0.08))
        ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: c.x - 262, y: c.y - 262, width: 524, height: 524))
        ctx.setStrokeColor(rgb(0, 0, 0, 0.6)); ctx.setLineWidth(6); ctx.strokePath()

        // Aperture: six blades around a hexagonal opening.
        let r0: CGFloat = 112, rim: CGFloat = 250
        let rot = -Double.pi / 12
        let verts = (0..<6).map { i -> CGPoint in
            let a = rot + Double(i) * .pi / 3
            return CGPoint(x: c.x + r0 * cos(a), y: c.y + r0 * sin(a))
        }
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - rim, y: c.y - rim, width: rim * 2, height: rim * 2))
        ctx.clip()
        for i in 0..<6 {
            let v = verts[i], next = verts[(i + 1) % 6], prev = verts[(i + 5) % 6]
            let dx = v.x - prev.x, dy = v.y - prev.y
            let len = hypot(dx, dy)
            let far = CGPoint(x: v.x + dx / len * 600, y: v.y + dy / len * 600)
            let ndx = next.x - v.x, ndy = next.y - v.y, nlen = hypot(ndx, ndy)
            let farNext = CGPoint(x: next.x + ndx / nlen * 600, y: next.y + ndy / nlen * 600)
            let blade = CGMutablePath()
            blade.move(to: v); blade.addLine(to: far); blade.addLine(to: farNext); blade.addLine(to: next); blade.closeSubpath()
            ctx.addPath(blade)
            let shade = 0.15 + 0.035 * Double(i)
            ctx.setFillColor(rgb(shade, shade, shade + 0.03))
            ctx.fillPath()
            ctx.move(to: v); ctx.addLine(to: far)
            ctx.setStrokeColor(rgb(1, 1, 1, 0.12)); ctx.setLineWidth(3); ctx.strokePath()
        }
        ctx.restoreGState()

        // Opening: a warm sunset seen through the lens.
        let hex = CGMutablePath()
        hex.addLines(between: verts); hex.closeSubpath()
        ctx.saveGState()
        ctx.addPath(hex); ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(1, 0.78, 0.4), rgb(0.97, 0.42, 0.45), rgb(0.45, 0.3, 0.85)], [0, 0.5, 1]),
                               start: CGPoint(x: c.x, y: c.y + r0), end: CGPoint(x: c.x, y: c.y - r0), options: [])
        ctx.setFillColor(rgb(1, 0.95, 0.8, 0.95))
        ctx.fillEllipse(in: CGRect(x: c.x - 6, y: c.y + 4, width: 46, height: 46))
        ctx.restoreGState()

        // Glass highlight.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - 262, y: c.y - 262, width: 524, height: 524)); ctx.clip()
        ctx.drawRadialGradient(gradient([rgb(1, 1, 1, 0.16), rgb(1, 1, 1, 0)], [0, 1]),
                               startCenter: CGPoint(x: c.x - 110, y: c.y + 130), startRadius: 0,
                               endCenter: CGPoint(x: c.x - 110, y: c.y + 130), endRadius: 230, options: [])
        ctx.restoreGState()
    }
}

func wheel(_ ctx: CGContext) {
    drawBody(ctx) { ctx, body in
        ctx.drawLinearGradient(gradient([rgb(0.13, 0.12, 0.22), rgb(0.05, 0.05, 0.09)], [0, 1]),
                               start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        let c = CGPoint(x: 512, y: 512)
        hueRing(ctx, center: c, outer: 300, inner: 0, brightness: 0.95)
        ctx.addEllipse(in: CGRect(x: c.x - 300, y: c.y - 300, width: 600, height: 600))
        ctx.setStrokeColor(rgb(1, 1, 1, 0.25)); ctx.setLineWidth(6); ctx.strokePath()
        // The puck, pulled toward warm.
        let p = CGPoint(x: c.x + 150, y: c.y + 120)
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: rgb(0, 0, 0, 0.5))
        ctx.addEllipse(in: CGRect(x: p.x - 46, y: p.y - 46, width: 92, height: 92))
        ctx.setStrokeColor(rgb(1, 1, 1)); ctx.setLineWidth(16); ctx.strokePath()
    }
}

func landscape(_ ctx: CGContext) {
    drawBody(ctx) { ctx, body in
        ctx.drawLinearGradient(gradient([rgb(0.36, 0.3, 0.75), rgb(0.93, 0.45, 0.55), rgb(1, 0.78, 0.45)], [0, 0.6, 1]),
                               start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY + 260), options: [.drawsAfterEndLocation])
        ctx.setFillColor(rgb(1, 0.95, 0.78))
        ctx.fillEllipse(in: CGRect(x: 560, y: 520, width: 170, height: 170))
        let far = CGMutablePath()
        far.addLines(between: [CGPoint(x: 80, y: 380), CGPoint(x: 330, y: 640), CGPoint(x: 470, y: 500), CGPoint(x: 640, y: 680), CGPoint(x: 950, y: 360), CGPoint(x: 950, y: 80), CGPoint(x: 80, y: 80)])
        ctx.addPath(far); ctx.setFillColor(rgb(0.28, 0.2, 0.42)); ctx.fillPath()
        let near = CGMutablePath()
        near.addLines(between: [CGPoint(x: 80, y: 300), CGPoint(x: 400, y: 470), CGPoint(x: 620, y: 330), CGPoint(x: 950, y: 450), CGPoint(x: 950, y: 80), CGPoint(x: 80, y: 80)])
        ctx.addPath(near); ctx.setFillColor(rgb(0.13, 0.1, 0.2)); ctx.fillPath()
        // A slider track across the bottom: it's an editor.
        ctx.setFillColor(rgb(1, 1, 1, 0.35))
        ctx.fill(CGRect(x: 230, y: 200, width: 564, height: 10))
        ctx.setFillColor(rgb(1, 1, 1))
        ctx.fillEllipse(in: CGRect(x: 560, y: 175, width: 60, height: 60))
    }
}

func render(_ name: String, size: Int = 1024) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.interpolationQuality = .high
    switch name {
    case "wheel": wheel(ctx)
    case "landscape": landscape(ctx)
    default: aperture(ctx)
    }
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - Output

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(variant, size: base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(variant, size: base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let resources = root.appendingPathComponent("Resources")
try! fm.createDirectory(at: resources, withIntermediateDirectories: true)
let icns = resources.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)
writePNG(render(variant, size: 1024), resources.appendingPathComponent("AppIcon.png"))
print(p.terminationStatus == 0 ? "Wrote \(icns.path) (\(variant))" : "iconutil failed")

if let previewPath {
    let names = ["aperture", "wheel", "landscape"]
    let tile = 512, gap = 40
    let w = names.count * tile + (names.count + 1) * gap, h = tile + 2 * gap
    let sheet = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.setFillColor(rgb(0.93, 0.93, 0.94)); sheet.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
    sheet.setFillColor(rgb(0.12, 0.12, 0.13)); sheet.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
    for (i, n) in names.enumerated() {
        sheet.draw(render(n, size: tile), in: CGRect(x: gap + i * (tile + gap), y: gap, width: tile, height: tile))
    }
    writePNG(sheet.makeImage()!, URL(fileURLWithPath: previewPath))
    print("Wrote preview \(previewPath)")
}
