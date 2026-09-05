import AppKit

/// The only UI: a status item drawn as "C [57%] | X [96%]" and its drop-down menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var mode = DisplayMode.load()

    private let headerFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .semibold)
    private let detailFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
    /// Percentages on the colour chips read larger than the surrounding row text.
    private let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        // Informational rows are enabled view-based items with no action; without this
        // AppKit would flip every action-less item back to disabled on display.
        menu.autoenablesItems = false
        // Fixed width: rows are rebuilt on every refresh and mode switch, and the widest row
        // would otherwise resize the menu each time.
        menu.minimumWidth = 360
        statusItem.menu = menu
        store.onChange = { [weak self] in self?.render() }
        render()
    }

    func render() {
        if let button = statusItem.button {
            button.image = StatusTitleImage.make(titleSegments())
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.title = ""
        }
        rebuildMenu()
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        store.refreshIfStale()
    }

    // MARK: - Title

    /// "C [57%] | X [96%]": one chip per provider (Claude: session; Codex: session, else weekly).
    private func titleSegments() -> [StatusTitleImage.Segment] {
        var segments: [StatusTitleImage.Segment] = []
        for (index, kind) in ProviderKind.allCases.enumerated() {
            if index > 0 { segments += [.gap(5), .text("|"), .gap(5)] }
            segments += [.text(kind.shortLabel), .gap(3)]
            if let window = store.statuses[kind]?.snapshot.flatMap({ kind.menuBarWindow(in: $0) }) {
                segments.append(.chip("\(Format.percent(window, mode: mode))%", UsageColor.forUsed(window.usedPercent)))
            } else {
                segments.append(.text("–"))
            }
        }
        return segments
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()
        for kind in ProviderKind.allCases {
            let status = store.statuses[kind] ?? ProviderStatus()
            var header = kind.displayName
            if let plan = status.snapshot?.planLabel { header += " · \(plan)" }
            menu.addItem(headerItem(header, detail: status.snapshot?.accountLabel))

            if let snapshot = status.snapshot {
                let labelWidth = max(8, snapshot.extras.map { $0.label.count }.max() ?? 0)
                menu.addItem(usageItem(label: "Session", width: labelWidth, window: snapshot.session))
                menu.addItem(usageItem(label: "Weekly", width: labelWidth, window: snapshot.weekly))
                for extra in snapshot.extras {
                    menu.addItem(usageItem(label: extra.label, width: labelWidth, window: extra.window))
                }
                if let credits = snapshot.resetCredits {
                    menu.addItem(resetCreditsItem(label: "Resets", width: labelWidth, credits: credits))
                }
                if let tokens = snapshot.tokensToday {
                    menu.addItem(tokensItem(label: "Today", width: labelWidth, tokens: tokens))
                }
                if let note = snapshot.sourceNote {
                    menu.addItem(detailItem("ⓘ \(truncate(note))", color: .secondaryLabelColor))
                }
            }
            if let error = status.errorMessage {
                menu.addItem(detailItem("⚠ \(truncate(error))", color: .systemOrange))
            } else if status.snapshot == nil {
                menu.addItem(detailItem(status.isLoading ? "Loading…" : "No data yet", color: .secondaryLabelColor))
            }
            menu.addItem(.separator())
        }

        // Switch off = Used, on = Remaining; the active side is drawn in full label colour.
        let modeRow = ToggleRowView(offTitle: "Used", onTitle: "Remaining", isOn: mode == .remaining)
        modeRow.onChange = { [weak self] isOn in self?.setMode(isOn ? .remaining : .used) }
        let modeToggle = NSMenuItem(title: "Used / Remaining", action: nil, keyEquivalent: "")
        modeToggle.view = modeRow
        menu.addItem(modeToggle)
        menu.addItem(.separator())

        let isUpdating = store.statuses.values.contains { $0.isLoading }
        let detail = isUpdating ? "Loading…" : (store.lastRefresh.map { Format.time($0) } ?? "Not updated yet")
        let refreshRow = ActionRowView(title: "Refresh Now", detail: detail)
        refreshRow.action = { [weak self] in self?.refreshNow() }
        // Keeps ⌘R working while the menu is open; the row view draws the label and the time.
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.view = refreshRow
        menu.addItem(refresh)
        menu.addItem(.separator())
        // Own selector: macOS decorates the standard terminate: item with a glyph.
        let quit = NSMenuItem(title: "Quit QuotaBar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Informational rows are plain labels hosted in a custom view: no action, no hover
    /// highlight, and the text colour is exactly what we set (a disabled NSMenuItem
    /// would be drawn dimmed regardless of its attributed title).
    private func headerItem(_ title: String, detail: String? = nil) -> NSMenuItem {
        let row = HeaderRowView(title: title, detail: detail, titleFont: headerFont,
                                detailFont: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small)))
        let item = NSMenuItem(title: detail.map { "\(title)  \($0)" } ?? title, action: nil, keyEquivalent: "")
        item.view = row
        return item
    }

    private func detailItem(_ text: String, color: NSColor = .labelColor) -> NSMenuItem {
        labelItem(text, font: detailFont, color: color, indent: 12)
    }

    /// "Session  [64%]  3小时52分钟 (20:50)" — the percentage sits on a colour chip, the reset time follows.
    private func usageItem(label: String, width: Int, window: UsageWindow?) -> NSMenuItem {
        let value: NSView
        if let window {
            value = BadgeView(text: "\(Format.percent(window, mode: mode))%", fill: UsageColor.forUsed(window.usedPercent), font: chipFont)
        } else {
            value = plainValue("n/a", color: .secondaryLabelColor)
        }
        let item = detailRow(label: label, width: width, value: value, trailing: window.map(Format.resetText) ?? "")
        item.title = "\(label) \(Format.windowLine(window, mode: mode))"
        return item
    }

    /// "Resets  2                expires 10月4日"
    private func resetCreditsItem(label: String, width: Int, credits: ResetCredits) -> NSMenuItem {
        let trailing = credits.earliestExpiry.map { "expires \(Format.shortDate($0))" } ?? ""
        let item = detailRow(label: label, width: width, value: plainValue(String(credits.availableCount), color: .labelColor), trailing: trailing)
        item.title = "\(label) \(credits.availableCount) \(trailing)"
        return item
    }

    /// "Today  1.2M" — tokens consumed today on this Mac.
    private func tokensItem(label: String, width: Int, tokens: Int) -> NSMenuItem {
        let item = detailRow(label: label, width: width, value: plainValue(Format.tokens(tokens), color: .labelColor), trailing: "")
        item.title = "\(label) \(Format.tokens(tokens)) tokens"
        return item
    }

    private func plainValue(_ text: String, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = detailFont
        field.textColor = color
        return field
    }

    /// Indented row: monospaced name column, a value view, and right-aligned trailing text.
    private func detailRow(label: String, width: Int, value: NSView, trailing: String) -> NSMenuItem {
        let leftInset: CGFloat = 14 + 12
        let rightInset: CGFloat = 14
        let gap: CGFloat = 8
        let rowHeight: CGFloat = 24

        let name = NSTextField(labelWithString: label.padding(toLength: width, withPad: " ", startingAt: 0))
        name.font = detailFont
        name.textColor = .labelColor

        let trailingLabel = NSTextField(labelWithString: trailing)
        trailingLabel.font = detailFont
        trailingLabel.textColor = .labelColor
        trailingLabel.alignment = .right

        let row = NSView(frame: .zero)
        row.autoresizingMask = [.width]
        for view in [name, value, trailingLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: leftInset),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            value.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: gap),
            value.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // Reset time / expiry hugs the right edge, in line with the header's account label.
            trailingLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -rightInset),
            trailingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: value.trailingAnchor, constant: gap),
            trailingLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        let naturalWidth = leftInset + name.fittingSize.width + gap + value.fittingSize.width + gap + trailingLabel.fittingSize.width + rightInset
        row.frame = NSRect(x: 0, y: 0, width: ceil(naturalWidth), height: rowHeight)

        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        item.view = row
        return item
    }

    private func labelItem(_ text: String, font: NSFont, color: NSColor, indent: CGFloat) -> NSMenuItem {
        labelItem(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]), indent: indent)
    }

    private func labelItem(_ text: NSAttributedString, indent: CGFloat) -> NSMenuItem {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = text
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()

        let leftInset: CGFloat = 14 + indent
        let rightInset: CGFloat = 14
        let verticalPad: CGFloat = 3
        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: leftInset + label.frame.width + rightInset,
            height: label.frame.height + verticalPad * 2
        ))
        label.frame.origin = NSPoint(x: leftInset, y: verticalPad)
        container.addSubview(label)

        let item = NSMenuItem(title: text.string, action: nil, keyEquivalent: "")
        item.view = container
        return item
    }

    private func truncate(_ text: String, limit: Int = 96) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    @objc private func refreshNow() {
        Task { await store.refresh(force: true) }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func setMode(_ newMode: DisplayMode) {
        guard newMode != mode else { return }
        mode = newMode
        mode.save()
        // Let the switch finish its click before the menu rows are rebuilt underneath it.
        DispatchQueue.main.async { [weak self] in self?.render() }
    }
}
