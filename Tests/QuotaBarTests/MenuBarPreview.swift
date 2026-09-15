import XCTest
import AppKit
@testable import QuotaBar

/// Renders the real menu bar image, riders included, at actual size and enlarged.
final class MenuBarPreview: XCTestCase {
    func testWriteMenuBarSheet() throws {
        guard let out = ProcessInfo.processInfo.environment["MENUBAR_OUT"] else {
            throw XCTSkip("set MENUBAR_OUT to render")
        }
        let statuses = PreviewData.statuses()
        // Claude steady, Codex sprinting: the pair that has to stay legible side by side.
        let poses: [ProviderKind: CyclistFrame] = [.claude: CyclistFrame(cadence: .normal, index: 2),
                                                   .codex: CyclistFrame(cadence: .standing, index: 5)]

        struct Row { let caption: String; let style: MenuBarStyle; let colors: IndicatorColorMode }
        let rows = [Row(caption: "ring · usage colors", style: .ring, colors: .usage),
                    Row(caption: "ring · monochrome", style: .ring, colors: .monochrome),
                    Row(caption: "badge · usage colors", style: .percentageBadge, colors: .usage),
                    Row(caption: "bar · monochrome", style: .bar, colors: .monochrome)]

        let rowHeight: CGFloat = 116
        let sheet = NSSize(width: 980, height: rowHeight * CGFloat(rows.count) + 20)
        let image = NSImage(size: sheet)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: sheet).fill()

        for (index, row) in rows.enumerated() {
            var settings = Settings.default
            settings.showCyclist = true
            settings.menuBarStyle = row.style
            settings.colorMode = row.colors
            let top = sheet.height - CGFloat(index) * rowHeight - 24
            (row.caption as NSString).draw(at: NSPoint(x: 16, y: top),
                                           withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                            .foregroundColor: NSColor.black])

            for (column, appearance) in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)].enumerated() {
                let light = column == 0
                let originX: CGFloat = 16 + CGFloat(column) * 480
                appearance?.performAsCurrentDrawingAppearance {
                    let bar = StatusTitleImage.make(statuses: statuses, settings: settings,
                                                    mode: .used, cyclists: poses)
                    // Actual size, on a menu bar of the matching appearance.
                    let strip = NSRect(x: originX, y: top - 34, width: bar.size.width + 20, height: 26)
                    (light ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
                    strip.fill()
                    bar.draw(in: NSRect(x: strip.minX + 10, y: strip.minY + 2, width: bar.size.width, height: 22))

                    // Enlarged, to judge the drawing rather than the screen.
                    let zoom: CGFloat = 2.6
                    let big = NSRect(x: originX, y: top - 44 - 22 * zoom,
                                     width: bar.size.width * zoom, height: 22 * zoom)
                    (light ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
                    big.insetBy(dx: -6, dy: -4).fill()
                    bar.draw(in: big)
                }
            }
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no png") }
        try png.write(to: URL(fileURLWithPath: out))
    }
}
