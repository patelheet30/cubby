// Renders Cubby's app icon (a drawer with clip cards sticking out, on a macOS-style rounded square) into AppIcon.icns.
// Usage: swiftc -O Resources/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/AppIcon.icns
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ v: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

/// One clip card: coloured, rotated about its bottom centre, with two "text" lines.
func card(_ ctx: CGContext, centerX: CGFloat, top: CGFloat, angle: CGFloat, color: Int) {
    let w: CGFloat = 230, h: CGFloat = 330
    ctx.saveGState()
    ctx.translateBy(x: centerX, y: top + h)
    ctx.rotate(by: angle * .pi / 180)
    let r = CGRect(x: -w / 2, y: -h, width: w, height: h)
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: hex(0x5A1A00, 0.28))
    ctx.addPath(rounded(r, 34)); ctx.setFillColor(hex(color)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(hex(0xFFFFFF, 0.85))
    ctx.addPath(rounded(CGRect(x: r.minX + 36, y: r.minY + 44, width: 120, height: 22), 11)); ctx.fillPath()
    ctx.setFillColor(hex(0xFFFFFF, 0.55))
    ctx.addPath(rounded(CGRect(x: r.minX + 36, y: r.minY + 84, width: 158, height: 22), 11)); ctx.fillPath()
    ctx.restoreGState()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1) // top-left origin
    // Apple's icon grid: an 824pt body centred on a 1024 canvas with ~185pt continuous corners.
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824), shape = rounded(rect, 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: hex(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(hex(0xFF8A47)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: srgb, colors: [hex(0xFFC15A), hex(0xFF8A47), hex(0xF2594B)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: srgb, colors: [hex(0xFFFFFF, 0.30), hex(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 170), startRadius: 0, endCenter: CGPoint(x: 330, y: 170), endRadius: 620, options: [])

    // Cards first (their bottoms disappear into the drawer), then the drawer front over them.
    card(ctx, centerX: 405, top: 268, angle: -11, color: 0xEEC34F)
    card(ctx, centerX: 619, top: 268, angle: 11, color: 0x6FCF6A)
    card(ctx, centerX: 512, top: 228, angle: 0, color: 0x4DA3F7)

    let drawer = CGRect(x: 218, y: 548, width: 588, height: 270)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: hex(0x5A1A00, 0.30))
    ctx.addPath(rounded(drawer, 64)); ctx.setFillColor(hex(0xFFFBF6)); ctx.fillPath()
    ctx.restoreGState()
    let lip = CGGradient(colorsSpace: srgb, colors: [hex(0xFFFFFF, 1), hex(0xF3E7DC, 1)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(rounded(drawer, 64)); ctx.clip()
    ctx.drawLinearGradient(lip, start: CGPoint(x: 0, y: drawer.minY), end: CGPoint(x: 0, y: drawer.maxY), options: [])
    ctx.restoreGState()
    ctx.addPath(rounded(CGRect(x: 512 - 100, y: drawer.midY - 20, width: 200, height: 40), 20))
    ctx.setFillColor(hex(0xF07A45)); ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(shape); ctx.setStrokeColor(hex(0xFFFFFF, 0.18)); ctx.setLineWidth(3); ctx.strokePath()
    return ctx.makeImage()!
}

let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    let data = NSBitmapImageRep(cgImage: render(size * scale)).representation(using: .png, properties: [:])!
    try! data.write(to: set.appendingPathComponent(name))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try! NSBitmapImageRep(cgImage: render(1024)).representation(using: .png, properties: [:])!
    .write(to: out.deletingPathExtension().appendingPathExtension("png"))
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
