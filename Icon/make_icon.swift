// Generates Icon/AppIcon.icns (design 1: "Flow" arrows). Run: swift Icon/make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    // Flip to SVG-like coordinates (y down), 100-unit design box inside the macOS 824pt icon grid.
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 100, y: 100); ctx.scaleBy(x: 8.24, y: 8.24)

    let body = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 1.2), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(body); ctx.setFillColor(NSColor(srgbRed: 0.09, green: 0.37, blue: 0.65, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 0.24, green: 0.58, blue: 0.90, alpha: 1).cgColor,
        NSColor(srgbRed: 0.07, green: 0.30, blue: 0.56, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    ctx.setLineWidth(9); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    func arrow(_ pts: [[CGFloat]], _ color: NSColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.move(to: CGPoint(x: pts[0][0], y: pts[0][1])); ctx.addLine(to: CGPoint(x: pts[1][0], y: pts[1][1])); ctx.strokePath()
        ctx.move(to: CGPoint(x: pts[2][0], y: pts[2][1]))
        for p in pts[3...] { ctx.addLine(to: CGPoint(x: p[0], y: p[1])) }
        ctx.strokePath()
    }
    arrow([[34, 22], [34, 62], [24, 53], [34, 65], [44, 53]], .white)
    arrow([[66, 78], [66, 38], [56, 47], [66, 35], [76, 47]], NSColor(srgbRed: 0.62, green: 0.80, blue: 0.97, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon")
let set = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: dir.appendingPathComponent("AppIcon-1024.png"))
