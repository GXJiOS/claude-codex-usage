import AppKit

/// Draws the menu bar title ("C [89%] | X [96%]") as an image so the percentages can
/// sit on rounded colour chips, which an NSStatusBarButton title cannot render. The
/// drawing handler runs at draw time, so `labelColor` follows the menu bar's own light /
/// dark appearance.
enum StatusTitleImage {
    enum Segment {
        case text(String)
        /// A chip hugs its text, but occupies a slot as wide as "99%" so the status item
        /// keeps the same width for any value below 100% (100% widens it by one digit).
        case chip(String, NSColor)
        /// Fixed horizontal gap in points.
        case gap(CGFloat)
    }

    private static let widestChipText = "99%"

    private static let height: CGFloat = 22
    private static let chipHeight: CGFloat = 17
    private static let chipRadius: CGFloat = 4
    private static let chipPad: CGFloat = 5
    private static let textFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    static func make(_ segments: [Segment]) -> NSImage {
        let widths = segments.map(width)
        let total = widths.reduce(0, +)
        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (segment, width) in zip(segments, widths) {
                draw(segment, at: x, width: width)
                x += width
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func width(_ segment: Segment) -> CGFloat {
        switch segment {
        case .text(let text):
            return ceil(size(text, textFont).width)
        case .chip(let text, _):
            return max(ceil(size(widestChipText, chipFont).width), ceil(size(text, chipFont).width)) + chipPad * 2
        case .gap(let points):
            return points
        }
    }

    private static func draw(_ segment: Segment, at x: CGFloat, width: CGFloat) {
        switch segment {
        case .text(let text):
            let attributes: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: NSColor.labelColor]
            let textSize = size(text, textFont)
            text.draw(at: NSPoint(x: x, y: (height - textSize.height) / 2), withAttributes: attributes)
        case .chip(let text, let fill):
            let textWidth = ceil(size(text, chipFont).width) + chipPad * 2
            let rect = NSRect(x: x + (width - textWidth) / 2, y: (height - chipHeight) / 2, width: textWidth, height: chipHeight)
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: chipRadius, yRadius: chipRadius).fill()
            let textColor: NSColor = fill == .systemYellow ? .black : .white
            let attributes: [NSAttributedString.Key: Any] = [.font: chipFont, .foregroundColor: textColor]
            let textSize = size(text, chipFont)
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        case .gap:
            break
        }
    }

    private static func size(_ text: String, _ font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }
}
