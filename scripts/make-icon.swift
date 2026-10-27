// Renders Hark's app icon (a glowing orb on a dark squircle) into an .icns file.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit
import CoreGraphics

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let size = 1024
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let s = CGFloat(size)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// macOS icon grid: 824 pt squircle inside 1024 canvas.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
let squircle = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0, 0, 0, 0.45))
ctx.addPath(squircle)
ctx.setFillColor(color(0.05, 0.05, 0.08))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0.11, 0.10, 0.18), color(0.03, 0.03, 0.06)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: s / 2, y: rect.maxY), end: CGPoint(x: s / 2, y: rect.minY), options: [])

// The orb: overlapping soft lights, added together.
let center = CGPoint(x: s / 2, y: s / 2)
let radius: CGFloat = 250
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.clip()
ctx.setFillColor(color(0.02, 0.02, 0.05))
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
ctx.setBlendMode(.plusLighter)
let lights: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (0.00, 0.78, 1.00, -90, 70, 230),
    (0.37, 0.36, 0.90, 60, 110, 240),
    (0.75, 0.35, 0.95, 100, -40, 220),
    (1.00, 0.22, 0.37, -40, -110, 210),
    (1.00, 0.62, 0.04, -120, -40, 170),
]
for (r, g, b, dx, dy, rr) in lights {
    let gradient = CGGradient(colorsSpace: space, colors: [color(r, g, b, 0.95), color(r, g, b, 0)] as CFArray, locations: [0, 1])!
    let c = CGPoint(x: center.x + dx, y: center.y + dy)
    ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: rr, options: [])
}
let core = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.8), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(core, startCenter: center, startRadius: 0, endCenter: center, endRadius: 120, options: [])
ctx.setBlendMode(.normal)
let gloss = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.32), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: s / 2, y: center.y + radius), end: CGPoint(x: s / 2, y: center.y), options: [])
ctx.restoreGState()

// Halo around the orb.
ctx.setBlendMode(.plusLighter)
let halo = CGGradient(colorsSpace: space, colors: [color(0.37, 0.36, 0.90, 0.35), color(0.37, 0.36, 0.90, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(halo, startCenter: center, startRadius: radius * 0.95, endCenter: center, endRadius: radius * 1.45, options: [])
ctx.restoreGState()

// Hairline edge.
ctx.addPath(squircle)
ctx.setStrokeColor(color(1, 1, 1, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Hark.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: NSSize(width: size, height: size)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
