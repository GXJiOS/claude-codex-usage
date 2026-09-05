import AppKit

// QuotaBar app icon: full-bleed rounded square (no transparent margin), "C" in Claude
// orange and "X" in ChatGPT green, each over a quota bar.
// Usage: swift make_icon.swift <output.png> [pixels]
let args = CommandLine.arguments
let output = args.count > 1 ? args[1] : "QuotaBar-icon.png"
let pixels = args.count > 2 ? Int(args[2]) ?? 1024 : 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gc = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gc
let ctx = gc.cgContext
let s = CGFloat(pixels) / 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Plate: fills the canvas, macOS corner ratio.
let plate = CGRect(x: 0, y: 0, width: 1024 * s, height: 1024 * s)
ctx.saveGState()
ctx.addPath(rounded(plate, 1024 * 0.2237 * s))
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    rgb(52, 64, 92).cgColor, rgb(20, 26, 44).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(glow, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.midY), options: [])
ctx.restoreGState()

let claudeOrange = rgb(217, 119, 87)
let codexGreen = rgb(25, 195, 125)

// Two columns: letter above, quota bar below.
struct Column { let letter: String; let color: NSColor; let centerX: CGFloat; let fill: CGFloat }
let columns = [
    Column(letter: "C", color: claudeOrange, centerX: 300 * s, fill: 0.62),
    Column(letter: "X", color: codexGreen, centerX: 724 * s, fill: 0.88),
]
let barWidth = 300 * s
let barHeight = 64 * s
let barY = 280 * s
let font = NSFont.systemFont(ofSize: 420 * s, weight: .heavy)
    .fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 420 * s) }
    ?? NSFont.systemFont(ofSize: 420 * s, weight: .heavy)

for column in columns {
    // Letter, with a soft glow in its own colour.
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: column.color]
    let text = NSAttributedString(string: column.letter, attributes: attributes)
    let bounds = text.boundingRect(with: NSSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin])
    let origin = CGPoint(x: column.centerX - bounds.width / 2 - bounds.minX, y: 355 * s)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30 * s, color: column.color.withAlphaComponent(0.45).cgColor)
    text.draw(at: origin)
    ctx.restoreGState()

    // Bar: translucent track, white fill.
    let track = CGRect(x: column.centerX - barWidth / 2, y: barY, width: barWidth, height: barHeight)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    ctx.addPath(rounded(track, barHeight / 2))
    ctx.fillPath()
    let fill = CGRect(x: track.minX, y: barY, width: barWidth * column.fill, height: barHeight)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16 * s, color: column.color.withAlphaComponent(0.5).cgColor)
    ctx.setFillColor(column.color.cgColor)
    ctx.addPath(rounded(fill, barHeight / 2))
    ctx.fillPath()
    ctx.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output) (\(pixels)px)")
