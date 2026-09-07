import AppKit
import Combine

/// Both providers share a native menu with aligned values, quota chips, and account details.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let model: SettingsModel
    private var subscriptions = Set<AnyCancellable>()
    private var mode: DisplayMode { model.displayMode }

    /// Set by AppDelegate; opens the settings and history window.
    var onOpenWindow: (() -> Void)?

    private let headerFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .semibold)
    private let detailFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
    /// Percentages on the colour chips read larger than the surrounding row text.
    private let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    init(store: UsageStore, model: SettingsModel) {
        self.store = store
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        // Informational rows stay enabled while their custom views render.
        menu.autoenablesItems = false
        // Each menu starts at 360pt and accommodates its rows' intrinsic content widths.
        menu.minimumWidth = 360
        statusItem.menu = menu
        store.$statuses.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        store.$lastRefresh.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        render()
    }

    func render() {
        if let button = statusItem.button {
            button.image = StatusTitleImage.make(statuses: store.statuses, settings: model.settings, mode: mode)
            button.setAccessibilityLabel(L("Claude and Codex usage"))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.title = ""
        }
        rebuildMenu()
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        store.refreshIfStale()
    }

    /// Opens the status item's native menu, including explicit preview launches.
    func showPopover() {
        statusItem.button?.performClick(nil)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(toolbarItem())
        menu.addItem(.separator())
        for kind in ProviderKind.allCases {
            let status = store.statuses[kind] ?? ProviderStatus()
            var header = kind.displayName
            if let plan = status.snapshot?.planLabel { header += " · \(plan)" }
            menu.addItem(headerItem(header, detail: status.snapshot?.accountLabel))

            if let snapshot = status.snapshot {
                let labels = ["00000000", L("Session"), L("Weekly"), L("Today"), L("Resets")]
                    + snapshot.extras.map(\.label)
                let labelWidth = labels.map { text -> CGFloat in
                    let label = NSTextField(labelWithString: text)
                    label.font = detailFont
                    return ceil(label.fittingSize.width)
                }.max() ?? 0
                menu.addItem(usageItem(label: L("Session"), width: labelWidth, window: snapshot.session))
                menu.addItem(usageItem(label: L("Weekly"), width: labelWidth, window: snapshot.weekly))
                for extra in snapshot.extras where model.settings.showModels {
                    menu.addItem(usageItem(label: extra.label, width: labelWidth, window: extra.window))
                }
                if model.settings.showResetCredits, let credits = snapshot.resetCredits {
                    menu.addItem(resetCreditsItem(label: L("Resets"), width: labelWidth, credits: credits))
                }
                if model.settings.showTokens, let tokens = snapshot.tokensToday {
                    menu.addItem(tokensItem(label: L("Today"), width: labelWidth, tokens: tokens))
                }
                if let note = snapshot.sourceNote {
                    menu.addItem(detailItem("ⓘ \(truncate(note))", color: .secondaryLabelColor))
                }
            }
            if let error = status.localizedErrorMessage {
                menu.addItem(detailItem("⚠ \(truncate(error))", color: .systemOrange))
            } else if status.snapshot == nil {
                menu.addItem(detailItem(L(status.isLoading ? "Loading…" : "No data yet"), color: .secondaryLabelColor))
            }
            menu.addItem(.separator())
        }

        // Switch off = Used, on = Remaining; the active side is drawn in full label colour.
        let modeRow = ToggleRowView(offTitle: L("Used"), onTitle: L("Remaining"), isOn: mode == .remaining)
        modeRow.onChange = { [weak self] isOn in self?.setMode(isOn ? .remaining : .used) }
        let modeToggle = NSMenuItem(title: "\(L("Used")) / \(L("Remaining"))", action: nil, keyEquivalent: "")
        modeToggle.view = modeRow
        menu.addItem(modeToggle)
        menu.addItem(.separator())

        // Hidden action items retain the menu's keyboard shortcuts.
        for (title, action, key) in [(L("Refresh usage"), #selector(refreshNow), "r"),
                                      (L("Settings"), #selector(openWindow), ",")] {
            let shortcut = NSMenuItem(title: title, action: action, keyEquivalent: key)
            shortcut.target = self
            shortcut.isHidden = true
            shortcut.allowsKeyEquivalentWhenHidden = true
            menu.addItem(shortcut)
        }
        // Own selector: macOS decorates the standard terminate: item with a glyph.
        let quit = NSMenuItem(title: L("Quit QuotaBar"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func toolbarItem() -> NSMenuItem {
        let statuses = ProviderKind.allCases.map { store.statuses[$0] ?? ProviderStatus() }
        let isUpdating = statuses.contains { $0.isLoading }
        let hasIssues = statuses.contains { $0.errorMessage != nil || $0.snapshot?.sourceNote != nil }
        let connected = statuses.allSatisfy { $0.snapshot != nil }
        let detail: String
        if store.isPreview { detail = L("Preview data") }
        else if isUpdating { detail = L("Refreshing…") }
        else if hasIssues { detail = L("Connection needs attention") }
        else if connected, let oldest = statuses.compactMap({ $0.snapshot?.fetchedAt }).min() {
            detail = L("Updated %@", Format.time(oldest))
        } else { detail = L("Waiting for usage") }
        let row = MenuToolbarView(detail: detail,
                                  statusColor: hasIssues ? .systemOrange : connected ? .systemGreen : .secondaryLabelColor,
                                  refreshEnabled: !isUpdating)
        row.onRefresh = { [weak self] in self?.refreshNow() }
        row.onSettings = { [weak self] in self?.openWindow() }
        let item = NSMenuItem(title: "QuotaBar", action: nil, keyEquivalent: "")
        item.view = row
        return item
    }

    /// Enabled section headers align provider text with trailing account details.
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
    private func usageItem(label: String, width: CGFloat, window: UsageWindow?) -> NSMenuItem {
        let value: NSView
        if let window {
            value = BadgeView(text: "\(Format.percent(window, mode: mode))%",
                              fill: UsageColor.forUsed(window.usedPercent, thresholds: model.settings.usageColorThresholds), font: chipFont)
        } else {
            value = plainValue("n/a", color: .secondaryLabelColor)
        }
        let item = detailRow(label: label, width: width, value: value, trailing: window.map(resetText) ?? "")
        item.title = "\(label) \(Format.windowLine(window, mode: mode))"
        return item
    }

    /// "Resets  2                expires 10月4日"
    private func resetCreditsItem(label: String, width: CGFloat, credits: ResetCredits) -> NSMenuItem {
        let trailing = credits.earliestExpiry.map { L("expires %@", Format.shortDate($0)) } ?? ""
        let item = detailRow(label: label, width: width, value: plainValue(String(credits.availableCount), color: .labelColor), trailing: trailing)
        item.title = "\(label) \(credits.availableCount) \(trailing)"
        return item
    }

    /// "Today  1.2M" — tokens consumed today on this Mac.
    private func tokensItem(label: String, width: CGFloat, tokens: Int) -> NSMenuItem {
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
    private func detailRow(label: String, width: CGFloat, value: NSView, trailing: String) -> NSMenuItem {
        let leftInset: CGFloat = 14 + 12
        let rightInset: CGFloat = 14
        let gap: CGFloat = 8
        let rowHeight: CGFloat = 24

        let name = NSTextField(labelWithString: label)
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
            name.widthAnchor.constraint(equalToConstant: width),
            value.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: gap),
            value.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // Reset time / expiry hugs the right edge, in line with the header's account label.
            trailingLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -rightInset),
            trailingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: value.trailingAnchor, constant: gap),
            trailingLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        let naturalWidth = leftInset + width + gap + value.fittingSize.width + gap + trailingLabel.fittingSize.width + rightInset
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

    @objc private func openWindow() {
        menu.cancelTracking()
        onOpenWindow?()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func setMode(_ newMode: DisplayMode) {
        guard newMode != mode else { return }
        // Complete the native switch event before updating the shared model and its menu views.
        DispatchQueue.main.async { [weak self] in
            self?.model.showRemaining = newMode == .remaining
        }
    }

    private func resetText(_ window: UsageWindow) -> String {
        guard let reset = window.resetsAt else { return "" }
        switch model.settings.timeDisplay {
        case .both: return Format.resetText(window)
        case .resetTime: return Format.dateTime(reset)
        case .countdown: return Format.countdown(reset.timeIntervalSinceNow)
        }
    }
}

/// Shared menu actions sit beside the update status above both provider sections.
private final class MenuToolbarView: NSView {
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?

    init(detail: String, statusColor: NSColor, refreshEnabled: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 52))
        autoresizingMask = [.width]
        let title = NSTextField(labelWithString: "QuotaBar")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = .systemFont(ofSize: 10, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = statusColor.cgColor
        dot.layer?.cornerRadius = 3
        let refresh = iconButton(symbol: "arrow.clockwise", title: L("Refresh usage"), action: #selector(refreshClicked))
        refresh.isEnabled = refreshEnabled
        let settings = iconButton(symbol: "gearshape.fill", title: L("Settings"), action: #selector(settingsClicked))
        for view in [title, subtitle, dot, refresh, settings] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: refresh.leadingAnchor, constant: -12),
            dot.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: subtitle.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            subtitle.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: refresh.leadingAnchor, constant: -12),
            settings.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            settings.centerYAnchor.constraint(equalTo: centerYAnchor),
            settings.widthAnchor.constraint(equalToConstant: 24),
            settings.heightAnchor.constraint(equalToConstant: 24),
            refresh.trailingAnchor.constraint(equalTo: settings.leadingAnchor, constant: -6),
            refresh.centerYAnchor.constraint(equalTo: settings.centerYAnchor),
            refresh.widthAnchor.constraint(equalToConstant: 24),
            refresh.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func iconButton(symbol: String, title: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                              target: self, action: action)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    @objc private func refreshClicked() {
        DispatchQueue.main.async { [onRefresh] in onRefresh?() }
    }

    @objc private func settingsClicked() {
        DispatchQueue.main.async { [onSettings] in onSettings?() }
    }
}
