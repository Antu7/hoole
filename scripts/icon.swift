// Renders the 1024×1024 app icon: usage `swift scripts/icon.swift out.png`
// A cream paper tile with a faint grain, ink waveform markings, and a terracotta dot.
import AppKit

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

// macOS icon grid: 824 pt tile centered in 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Drop shadow under the tile.
NSGraphicsContext.saveGraphicsState()
let drop = NSShadow()
drop.shadowColor = .black.withAlphaComponent(0.22)
drop.shadowBlurRadius = 28
drop.shadowOffset = NSSize(width: 0, height: -12)
drop.set()
rgb(0.90, 0.87, 0.82).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Body: cream paper, a touch brighter at the top where the light falls.
NSGradient(colors: [rgb(0.985, 0.97, 0.94), rgb(0.953, 0.933, 0.894), rgb(0.90, 0.875, 0.825)],
           atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: shape, angle: -90)

// Paper grain: thousands of faint specks, seeded so every build draws the same icon.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
var seed: UInt64 = 0x484F4F4C
func random() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<26000 {
    let dark = random() < 0.6
    (dark ? rgb(0.35, 0.28, 0.2, 0.05 + random() * 0.05) : rgb(1, 1, 1, 0.10)).setFill()
    NSBezierPath(rect: NSRect(x: 100 + random() * 824, y: 100 + random() * 824, width: 2, height: 2)).fill()
}
NSGraphicsContext.restoreGraphicsState()

// Edge light: a thin bright rim along the top, fading out by the middle.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
rim.lineWidth = 6
rgb(1, 1, 1, 0.55).setStroke()
rim.stroke()
NSGraphicsContext.restoreGraphicsState()

// Waveform markings: five ink bars, slightly uneven like a real voice.
let ink = rgb(0.169, 0.153, 0.133)
let heights: [CGFloat] = [0.36, 0.70, 1.0, 0.58, 0.30]
let barWidth: CGFloat = 62, gap: CGFloat = 52, maxHeight: CGFloat = 400
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
for (i, h) in heights.enumerated() {
    let height = maxHeight * h
    let x = 512 - totalWidth / 2 + CGFloat(i) * (barWidth + gap)
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: 512 - height / 2, width: barWidth, height: height),
                           xRadius: barWidth / 2, yRadius: barWidth / 2)
    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = rgb(1, 1, 1, 0.7) // pressed into the paper: light catches the lower edge
    lift.shadowBlurRadius = 0
    lift.shadowOffset = NSSize(width: 0, height: -3)
    lift.set()
    ink.setFill()
    bar.fill()
    NSGraphicsContext.restoreGraphicsState()
}

// Terracotta dot, top right, like a stamp of ink.
let lamp = NSRect(x: 720, y: 720, width: 74, height: 74)
NSGraphicsContext.saveGraphicsState()
let glow = NSShadow()
glow.shadowColor = rgb(0.77, 0.33, 0.23, 0.25)
glow.shadowBlurRadius = 6
glow.set()
rgb(0.769, 0.333, 0.227).setFill()
NSBezierPath(ovalIn: lamp).fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
