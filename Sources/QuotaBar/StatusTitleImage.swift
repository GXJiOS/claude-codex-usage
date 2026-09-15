import AppKit

/// A menu bar image split into the part that only changes with the numbers and the
/// riders that change every frame, so animating costs one composite rather than a full
/// re-measure and redraw of the indicators.
struct StatusTitleLayout {
    struct Rider {
        let slot: NSRect
        let tint: NSColor
    }

    let base: NSImage
    let riders: [ProviderKind: Rider]
    var size: NSSize { base.size }
}

/// Native menu bar indicators share the settings page's live preview renderer.
enum StatusTitleImage {
    static func color(used: Double, mode: IndicatorColorMode, thresholds: UsageColorThresholds = .default) -> NSColor {
        switch mode {
        case .monochrome: return .labelColor
        case .accent: return .controlAccentColor
        case .usage:
            let color = UsageColor.forUsed(used, thresholds: thresholds)
            return color == .systemYellow ? .systemOrange : color
        }
    }

    /// Ready-to-show image, riders included. The status bar animates through
    /// `layout` + `compose` instead, to keep the indicators off the per-frame path.
    static func make(statuses: [ProviderKind: ProviderStatus], settings: Settings, mode: DisplayMode,
                     cyclists: [ProviderKind: CyclistFrame] = [:]) -> NSImage {
        compose(layout(statuses: statuses, settings: settings, mode: mode, withRiders: !cyclists.isEmpty),
                poses: cyclists)
    }

    static func compose(_ layout: StatusTitleLayout, poses: [ProviderKind: CyclistFrame]) -> NSImage {
        guard !poses.isEmpty, !layout.riders.isEmpty else { return layout.base }
        return bitmap(size: layout.size) {
            layout.base.draw(in: NSRect(origin: .zero, size: layout.size))
            for (provider, rider) in layout.riders {
                guard let pose = poses[provider] else { continue }
                CyclistSprite.image(pose, tint: rider.tint).draw(in: rider.slot)
            }
        }
    }

    static func layout(statuses: [ProviderKind: ProviderStatus], settings: Settings, mode: DisplayMode,
                       withRiders: Bool) -> StatusTitleLayout {
        let isBadge = settings.menuBarStyle == .percentageBadge
        let stackedLabels = settings.showLabels && (isBadge || settings.menuBarStyle == .bar || settings.menuBarStyle == .percentage)
        let font = NSFont.monospacedDigitSystemFont(ofSize: stackedLabels ? 10 : 12, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: stackedLabels ? 7 : 11, weight: .medium)
        let providerGap: CGFloat = isBadge || stackedLabels ? 4 : 12
        let indicatorWidths: [CGFloat] = ProviderKind.allCases.map { provider in
            switch settings.menuBarStyle {
            case .battery: return 28
            case .bar: return 32
            case .percentage:
                return stackedLabels ? ceil(("100%" as NSString).size(withAttributes: [.font: font]).width) + 2 : 38
            case .percentageBadge:
                let window = statuses[provider]?.snapshot.flatMap { provider.menuBarWindow(in: $0) }
                let text: String
                if let window, window.usedPercent.isFinite {
                    let amount = min(100, max(0, mode.value(usedPercent: window.usedPercent)))
                    text = "\(Int(amount.rounded()))%"
                } else { text = "–" }
                return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 8
            case .ring: return 20
            }
        }
        // The rider sits at the head of its provider's column.
        let cyclistWidth: CGFloat = withRiders ? CyclistSprite.size.width + 2 : 0
        let nameWidths = ProviderKind.allCases.map {
            settings.showLabels ? ceil(($0.displayName as NSString).size(withAttributes: [.font: labelFont]).width) : 0
        }
        let labelWidths = nameWidths.map { !stackedLabels && !isBadge && settings.showLabels ? $0 + 4 : 0 }
        let columnWidths = indicatorWidths.indices.map {
            cyclistWidth + (stackedLabels ? max(indicatorWidths[$0], nameWidths[$0] + 2)
                                          : indicatorWidths[$0] + labelWidths[$0])
        }
        let totalWidth = columnWidths.reduce(0, +) + providerGap
        let size = NSSize(width: totalWidth, height: 22)

        var riders: [ProviderKind: StatusTitleLayout.Rider] = [:]
        if withRiders {
            var origin: CGFloat = 0
            for (index, provider) in ProviderKind.allCases.enumerated() {
                defer { origin += columnWidths[index] + providerGap }
                // A provider with no numbers yet gets a plain rider rather than a colour
                // that would read as a usage level.
                let used = statuses[provider]?.snapshot.flatMap { provider.menuBarWindow(in: $0) }?.usedPercent
                let tint = color(used: used ?? 0, mode: used == nil ? .monochrome : settings.colorMode,
                                 thresholds: settings.usageColorThresholds)
                riders[provider] = StatusTitleLayout.Rider(
                    slot: NSRect(x: origin, y: 0, width: CyclistSprite.size.width, height: CyclistSprite.size.height),
                    tint: tint)
            }
        }

        let base = bitmap(size: size) {
            var origin: CGFloat = cyclistWidth
            for (index, provider) in ProviderKind.allCases.enumerated() {
                let indicatorWidth = indicatorWidths[index]
                let columnWidth = columnWidths[index] - cyclistWidth
                let labelWidth = labelWidths[index]
                defer { origin += columnWidths[index] + providerGap }
                if stackedLabels {
                    drawText(provider.displayName, in: NSRect(x: origin, y: 13.5, width: columnWidth, height: 8.5),
                             font: labelFont, color: .white)
                } else if labelWidth > 0 {
                    drawText(provider.displayName, in: NSRect(x: origin, y: 0, width: nameWidths[index], height: 22),
                             font: labelFont, color: .white)
                }
                let indicatorX = stackedLabels ? origin + (columnWidth - indicatorWidth) / 2 : origin + labelWidth
                let rect = NSRect(x: indicatorX, y: 0, width: indicatorWidth, height: 22)
                guard let window = statuses[provider]?.snapshot.flatMap({ provider.menuBarWindow(in: $0) }),
                      window.usedPercent.isFinite else {
                    let placeholder = NSRect(x: rect.minX, y: 0, width: rect.width, height: stackedLabels ? 13 : 22)
                    drawText("–", in: placeholder, font: font, color: .secondaryLabelColor)
                    continue
                }
                let amount = min(100, max(0, mode.value(usedPercent: window.usedPercent)))
                let fraction = amount / 100
                let tint = color(used: window.usedPercent, mode: settings.colorMode, thresholds: settings.usageColorThresholds)
                switch settings.menuBarStyle {
                case .percentage:
                    let valueRect = NSRect(x: rect.minX, y: 0, width: rect.width, height: stackedLabels ? 13 : 22)
                    drawText("\(Int(amount.rounded()))%", in: valueRect, font: font, color: tint)
                case .percentageBadge:
                    let text = "\(Int(amount.rounded()))%"
                    let chip = NSRect(x: rect.minX, y: stackedLabels ? 0 : 2.5,
                                      width: rect.width, height: stackedLabels ? 13 : 17)
                    let fill = settings.colorMode == .usage
                        ? UsageColor.forUsed(window.usedPercent, thresholds: settings.usageColorThresholds) : tint
                    fill.setFill()
                    let radius: CGFloat = stackedLabels ? 3 : 4
                    NSBezierPath(roundedRect: chip, xRadius: radius, yRadius: radius).fill()
                    let textColor: NSColor
                    switch settings.colorMode {
                    case .usage: textColor = fill == .systemYellow ? .black : .white
                    case .monochrome: textColor = .textBackgroundColor
                    case .accent:
                        let rgb = fill.usingColorSpace(.sRGB)
                        let brightness = rgb.map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent } ?? 0
                        textColor = brightness > 0.6 ? .black : .white
                    }
                    drawText(text, in: chip, font: font, color: textColor)
                case .ring:
                    let center = NSPoint(x: rect.midX, y: 11)
                    NSColor.labelColor.withAlphaComponent(0.15).setStroke()
                    let track = NSBezierPath(ovalIn: NSRect(x: center.x - 8, y: 3, width: 16, height: 16))
                    track.lineWidth = 3
                    track.stroke()
                    if fraction > 0 {
                        let arc = NSBezierPath()
                        arc.appendArc(withCenter: center, radius: 8, startAngle: 90,
                                      endAngle: 90 - CGFloat(fraction * 360), clockwise: true)
                        arc.lineWidth = 3
                        arc.lineCapStyle = .round
                        tint.setStroke()
                        arc.stroke()
                    }
                case .bar, .battery:
                    let battery = settings.menuBarStyle == .battery
                    let track = NSRect(x: rect.minX + (battery ? 2 : 0), y: stackedLabels ? 3.5 : battery ? 7 : 8,
                                       width: rect.width - (battery ? 7 : 0), height: battery ? 8 : 6)
                    NSColor.labelColor.withAlphaComponent(0.15).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                    if fraction > 0 {
                        tint.setFill()
                        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                                        width: track.width * fraction, height: track.height),
                                     xRadius: 2, yRadius: 2).fill()
                    }
                    if battery {
                        NSColor.secondaryLabelColor.setStroke()
                        let outline = NSBezierPath(roundedRect: track.insetBy(dx: -2, dy: -2), xRadius: 3, yRadius: 3)
                        outline.lineWidth = 1
                        outline.stroke()
                        NSColor.secondaryLabelColor.setFill()
                        NSBezierPath(roundedRect: NSRect(x: track.maxX + 3, y: 9, width: 2, height: 4),
                                     xRadius: 1, yRadius: 1).fill()
                    }
                }
            }
        }
        return StatusTitleLayout(base: base, riders: riders)
    }

    /// Renders into a real bitmap rather than a drawing handler, so redisplay blits the
    /// pixels instead of re-running the drawing code. Dynamic colours are resolved against
    /// the app's appearance, which is where the status item lives.
    private static func bitmap(size: NSSize, draw: () -> Void) -> NSImage {
        let scale: CGFloat = 2
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return NSImage(size: size)
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    private static func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                               withAttributes: attributes)
    }
}
