import AppKit

/// Clickable menu row with a left title and a right-aligned detail ("Refresh Now … 16:42").
/// Hosted as an NSMenuItem view, so it paints its own hover band; the menu stays open on
/// click so the detail can be watched changing ("Loading…" → new time).
final class ActionRowView: NSView {
    private static let horizontalInset: CGFloat = 14
    private static let rowHeight: CGFloat = 22

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    var action: (() -> Void)?

    init(title: String, detail: String) {
        super.init(frame: .zero)
        autoresizingMask = [.width]

        let font = NSFont.menuFont(ofSize: 0)
        titleLabel.stringValue = title
        titleLabel.font = font
        titleLabel.textColor = .labelColor
        detailLabel.stringValue = detail
        detailLabel.font = font
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right

        for label in [titleLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 24),
        ])

        // NSMenu takes the initial frame as the row's natural size, then stretches it to the menu width.
        let naturalWidth = Self.horizontalInset * 2 + titleLabel.fittingSize.width + 24 + detailLabel.fittingSize.width
        frame = NSRect(x: 0, y: 0, width: ceil(naturalWidth), height: Self.rowHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) {
        // Let the click finish before the menu rows (this view included) are rebuilt.
        DispatchQueue.main.async { [action] in action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered || enclosingMenuItem?.isHighlighted == true else { return }
        let band = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        band.fill()
    }
}

/// Menu row reading "Used  (switch)  Remaining": off selects the left word, on the right
/// one, and the selected word is drawn in full label colour. Clicking anywhere on the row
/// flips the switch; the menu stays open so the numbers can be seen changing.
final class ToggleRowView: NSView {
    private static let horizontalInset: CGFloat = 14
    private static let gap: CGFloat = 10
    private static let rowHeight: CGFloat = 26

    private let offLabel = NSTextField(labelWithString: "")
    private let onLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()

    var onChange: ((Bool) -> Void)?

    init(offTitle: String, onTitle: String, isOn: Bool) {
        super.init(frame: .zero)
        autoresizingMask = [.width]

        let font = NSFont.menuFont(ofSize: 0)
        offLabel.stringValue = offTitle
        offLabel.font = font
        onLabel.stringValue = onTitle
        onLabel.font = font

        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(switchChanged)
        updateLabelColors()

        for view in [offLabel, toggle, onLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            offLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            offLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.leadingAnchor.constraint(equalTo: offLabel.trailingAnchor, constant: Self.gap),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            onLabel.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: Self.gap),
            onLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let naturalWidth = Self.horizontalInset * 2 + offLabel.fittingSize.width + Self.gap
            + toggle.fittingSize.width + Self.gap + onLabel.fittingSize.width
        frame = NSRect(x: 0, y: 0, width: ceil(naturalWidth), height: Self.rowHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A click on the row (outside the switch itself) flips the switch too.
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !toggle.frame.contains(point) else { return }
        toggle.animator().state = toggle.state == .on ? .off : .on
        switchChanged()
    }

    @objc private func switchChanged() {
        updateLabelColors()
        onChange?(toggle.state == .on)
    }

    private func updateLabelColors() {
        let isOn = toggle.state == .on
        offLabel.textColor = isOn ? .secondaryLabelColor : .labelColor
        onLabel.textColor = isOn ? .labelColor : .secondaryLabelColor
    }
}

/// Section header: bold title on the left, a muted detail (the signed-in account) on the right.
final class HeaderRowView: NSView {
    private static let horizontalInset: CGFloat = 14
    private static let rowHeight: CGFloat = 24

    init(title: String, detail: String?, titleFont: NSFont, detailFont: NSFont) {
        super.init(frame: .zero)
        autoresizingMask = [.width]

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = titleFont
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        var naturalWidth = Self.horizontalInset * 2 + titleLabel.fittingSize.width
        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = detailFont
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.alignment = .right
            detailLabel.lineBreakMode = .byTruncatingMiddle
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(detailLabel)
            NSLayoutConstraint.activate([
                detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
                detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 24),
            ])
            naturalWidth += 24 + detailLabel.fittingSize.width
        }
        frame = NSRect(x: 0, y: 0, width: ceil(naturalWidth), height: Self.rowHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
