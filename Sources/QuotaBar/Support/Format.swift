import Foundation

enum Format {
    /// Presentation follows the selected application language.
    static var locale: Locale { L10n.locale }

    private static var clock: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    /// "周三 19:00" / "Wed 19:00"
    private static var weekdayClock: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "E HH:mm"
        return formatter
    }

    /// "3小时52分钟" / "3h 52m"
    private static var durationFormatter: DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }

    static func percent(_ window: UsageWindow?, mode: DisplayMode) -> String {
        guard let window else { return "–" }
        return String(Int(mode.value(usedPercent: window.usedPercent).rounded()))
    }

    /// Time until the window resets: "3小时52分钟 (20:50)" inside a day, "周三 19:00" beyond.
    /// Empty when the API gave no reset time.
    static func resetText(_ window: UsageWindow) -> String {
        guard let resetsAt = window.resetsAt else { return "" }
        let remaining = resetsAt.timeIntervalSinceNow
        if remaining < 24 * 3600 {
            return "\(duration(remaining)) (\(clock.string(from: resetsAt)))"
        }
        return weekdayClock.string(from: resetsAt)
    }

    /// Plain-text line for the CLI: "42%  3h 52m (20:50)".
    static func windowLine(_ window: UsageWindow?, mode: DisplayMode) -> String {
        guard let window else { return "n/a" }
        let reset = resetText(window)
        return reset.isEmpty ? "\(percent(window, mode: mode))%" : "\(percent(window, mode: mode))%  \(reset)"
    }

    /// "10月4日" / "Oct 4"
    private static var shortDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    static func countdown(_ interval: TimeInterval) -> String {
        let formatter = durationFormatter
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, interval)) ?? ""
    }

    static func time(_ date: Date) -> String {
        clock.string(from: date)
    }

    static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    private static var usesChineseUnits: Bool {
        locale.language.languageCode?.identifier == "zh"
    }

    /// Chinese system: "9876" / "1.6万" / "215万" / "1.25亿". Others: "999" / "46K" / "1.2M".
    static func tokens(_ count: Int) -> String {
        if usesChineseUnits {
            switch count {
            case 100_000_000...: return trimmed(String(format: "%.2f", Double(count) / 100_000_000)) + "亿"
            case 1_000_000...: return "\(Int((Double(count) / 10_000).rounded()))万"
            case 10_000...: return trimmed(String(format: "%.1f", Double(count) / 10_000)) + "万"
            default: return String(count)
            }
        }
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return "\(Int((Double(count) / 1_000).rounded()))K"
        default: return String(count)
        }
    }

    /// Drops a trailing ".0" / ".00" so "1.50" reads "1.5" and "2.00" reads "2".
    private static func trimmed(_ decimal: String) -> String {
        guard decimal.contains(".") else { return decimal }
        var text = decimal
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func duration(_ interval: TimeInterval) -> String {
        durationFormatter.string(from: max(60, interval)) ?? ""
    }
}
