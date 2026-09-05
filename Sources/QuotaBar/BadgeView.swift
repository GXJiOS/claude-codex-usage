import AppKit

/// Rounded solid-colour chip with a short label ("64%"). Text is black on yellow and
/// white on green/red so it reads on light and dark menus alike.
final class BadgeView: NSView {
    private static let horizontalPad: CGFloat = 8
    private static let verticalPad: CGFloat = 1
    private static let cornerRadius: CGFloat = 4

    private let fill: NSColor
    private let label = NSTextField(labelWithString: "")

    /// Every chip is as wide as "99%" would be (wider values stretch it), text centred.
    init(text: String, fill: NSColor, font: NSFont) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true

        label.stringValue = text
        label.font = font
        label.alignment = .center
        label.textColor = fill == .systemYellow ? .black : .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // Exact width, otherwise Auto Layout stretches the chip into any free space in the row.
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let standardWidth = ceil(("99%" as NSString).size(withAttributes: [.font: font]).width)
        let chipWidth = max(standardWidth, textWidth) + Self.horizontalPad * 2
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPad),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPad),
            widthAnchor.constraint(equalToConstant: chipWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = Self.cornerRadius
    }
}
