import XCTest
import AppKit
@testable import QuotaBar

/// Renders a contact sheet of every cadence and frame for eyeballing.
final class SpritePreview: XCTestCase {
    func testWriteContactSheet() throws {
        guard let out = ProcessInfo.processInfo.environment["SPRITE_OUT"] else {
            throw XCTSkip("set SPRITE_OUT to render")
        }
        let zoom: CGFloat = 8
        let cell = CyclistSprite.size
        // One row per cadence, plus the second parked pose.
        let rows: [(label: String, cadence: PedalCadence, parked: ParkedPose)] =
            PedalCadence.allCases.map { ($0.rawValue, $0, .sleeping) } + [("woodenFish", .idle, .woodenFish)]
        let cols = CyclistSprite.frameCount
        let labelWidth: CGFloat = 90
        let sheet = NSSize(width: labelWidth + CGFloat(cols) * cell.width * zoom,
                           height: CGFloat(rows.count) * cell.height * zoom + 60)

        let image = NSImage(size: sheet)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: sheet).fill()

        for (row, pose) in rows.enumerated() {
            let y = sheet.height - 60 - CGFloat(row + 1) * cell.height * zoom
            let label = pose.label as NSString
            label.draw(at: NSPoint(x: 8, y: y + cell.height * zoom / 2),
                       withAttributes: [.font: NSFont.systemFont(ofSize: 15),
                                        .foregroundColor: NSColor.black])
            for col in 0..<cols {
                let frame = CyclistFrame(cadence: pose.cadence, index: col, parked: pose.parked)
                let sprite = CyclistSprite.rendered(frame, tint: .black, scale: zoom)
                let rect = NSRect(x: labelWidth + CGFloat(col) * cell.width * zoom, y: y,
                                  width: cell.width * zoom, height: cell.height * zoom)
                sprite.draw(in: rect)
                NSColor(white: 0.85, alpha: 1).setStroke()
                NSBezierPath(rect: rect).stroke()
            }
        }

        // Actual size, as the menu bar shows it, on both backgrounds.
        for (index, background) in [NSColor.white, NSColor(white: 0.15, alpha: 1)].enumerated() {
            let stripY = sheet.height - 56 + CGFloat(index) * 26
            let stripRect = NSRect(x: labelWidth, y: stripY, width: 410, height: 24)
            background.setFill()
            stripRect.fill()
            var x = labelWidth + 6
            for pose in rows {
                for offset in 0..<3 {
                    let sprite = CyclistSprite.image(CyclistFrame(cadence: pose.cadence, index: offset * 2,
                                                                  parked: pose.parked),
                                                    tint: index == 0 ? .black : .white)
                    sprite.draw(in: NSRect(x: x, y: stripY + 1, width: cell.width, height: cell.height))
                    x += cell.width + 1
                }
                x += 10
            }
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("no png")
        }
        try png.write(to: URL(fileURLWithPath: out))
    }
}
