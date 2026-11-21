// Renders the CleanVoice app icon: a noisy waveform on the left resolving into a clean one on the right.
// Usage: swift make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.11, green: 0.16, blue: 0.33, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.42, blue: 0.55, alpha: 1)])!.draw(in: shape, angle: -60)
    let bars = 15
    let w = rect.width * 0.8 / CGFloat(bars * 2 - 1)
    var rng = SystemRandomNumberGenerator()
    for i in 0..<bars {
        let t = CGFloat(i) / CGFloat(bars - 1)
        let x = rect.minX + rect.width * 0.1 + CGFloat(i) * 2 * w
        let clean = 0.18 + 0.5 * sin(.pi * t) * (0.55 + 0.45 * sin(t * 9))
        let noisy = CGFloat.random(in: 0.25...0.75, using: &rng)
        let h = rect.height * (t < 0.45 ? noisy : abs(clean))
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - h / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2)
        NSColor(calibratedWhite: 1, alpha: t < 0.45 ? 0.45 : 0.95).setFill()
        bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
