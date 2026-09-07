import Foundation

extension Notification.Name {
    /// Posted after `Settings.save()`; `UsageStore` re-arms its timer on it.
    static let quotaBarSettingsChanged = Notification.Name("QuotaBarSettingsChanged")
}

/// User-tunable preferences, stored in UserDefaults next to `DisplayMode`.
struct Settings: Sendable, Equatable, Codable {
    /// Seconds between automatic refreshes.
    var refreshInterval: TimeInterval
    /// Days of history kept on disk; older records are pruned at launch.
    var historyRetentionDays: Int

    var menuBarStyle: MenuBarStyle = .ring
    var colorMode: IndicatorColorMode = .usage
    var usageColorThresholds: UsageColorThresholds = .default
    var theme: AppTheme = .system
    var showLabels = true
    var timeDisplay: ResetTimeDisplay = .both
    var showTokens = true
    var showModels = true
    var showResetCredits = true
    var notificationsEnabled = false
    var notificationThresholds = [75, 90, 95]
    var notificationSound = true
    var notifyOnReset = true
    var language: AppLanguage = .systemDefault()

    static let `default` = Settings(refreshInterval: 300, historyRetentionDays: 90)

    static let refreshIntervalChoices: [TimeInterval] = [60, 300, 600, 1800]
    static let retentionChoices: [Int] = [7, 30, 90, 365]

    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let historyRetentionDays = "historyRetentionDays"
    }

    static func load(from defaults: UserDefaults = .standard) -> Settings {
        var settings = defaults.data(forKey: "preferences.v1")
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings.default
        if let stored = defaults.object(forKey: Key.refreshInterval) as? Double,
           refreshIntervalChoices.contains(stored) {
            settings.refreshInterval = stored
        }
        if let stored = defaults.object(forKey: Key.historyRetentionDays) as? Int,
           retentionChoices.contains(stored) {
            settings.historyRetentionDays = stored
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "preferences.v1") }
        defaults.set(refreshInterval, forKey: Key.refreshInterval)
        defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays)
        defaults.set(language.rawValue, forKey: "appLanguage")
        NotificationCenter.default.post(name: .quotaBarSettingsChanged, object: nil)
    }
}

extension Settings {
    private enum CodingKeys: String, CodingKey {
        case refreshInterval, historyRetentionDays, menuBarStyle, colorMode, theme, showLabels
        case timeDisplay, showTokens, showModels, showResetCredits, notificationsEnabled
        case notificationThresholds, notificationSound, notifyOnReset, language
        case usageColorThresholds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(refreshInterval: try values.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 300,
                  historyRetentionDays: try values.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? 90)
        let storedStyle = try values.decodeIfPresent(String.self, forKey: .menuBarStyle)
        menuBarStyle = storedStyle == "compact" ? .percentageBadge
            : storedStyle.flatMap(MenuBarStyle.init(rawValue:)) ?? .ring
        colorMode = try values.decodeIfPresent(IndicatorColorMode.self, forKey: .colorMode) ?? .usage
        usageColorThresholds = (try? values.decode(UsageColorThresholds.self, forKey: .usageColorThresholds)) ?? .default
        theme = try values.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
        showLabels = try values.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        timeDisplay = try values.decodeIfPresent(ResetTimeDisplay.self, forKey: .timeDisplay) ?? .both
        showTokens = try values.decodeIfPresent(Bool.self, forKey: .showTokens) ?? true
        showModels = try values.decodeIfPresent(Bool.self, forKey: .showModels) ?? true
        showResetCredits = try values.decodeIfPresent(Bool.self, forKey: .showResetCredits) ?? true
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        notificationThresholds = try values.decodeIfPresent([Int].self, forKey: .notificationThresholds) ?? [75, 90, 95]
        notificationSound = try values.decodeIfPresent(Bool.self, forKey: .notificationSound) ?? true
        notifyOnReset = try values.decodeIfPresent(Bool.self, forKey: .notifyOnReset) ?? true
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .systemDefault()
    }
}

/// Ordered boundaries partition consumed quota into green, warning, and red ranges.
struct UsageColorThresholds: Codable, Equatable, Sendable {
    let yellowFrom: Int
    let redFrom: Int

    static let `default` = UsageColorThresholds()

    init(yellowFrom: Int = 50, redFrom: Int = 80) {
        if (1...99).contains(yellowFrom), (2...100).contains(redFrom), yellowFrom < redFrom {
            self.yellowFrom = yellowFrom
            self.redFrom = redFrom
        } else {
            self.yellowFrom = 50
            self.redFrom = 80
        }
    }

    private enum CodingKeys: String, CodingKey { case yellowFrom, redFrom }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(yellowFrom: try values.decode(Int.self, forKey: .yellowFrom),
                  redFrom: try values.decode(Int.self, forKey: .redFrom))
    }
}

enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
    case battery, bar, percentage, percentageBadge, ring

    var title: String {
        switch self {
        case .battery: return L("Battery")
        case .bar: return L("Progress Bar")
        case .percentage: return L("Percentage")
        case .percentageBadge: return L("Badge Percentage")
        case .ring: return L("Ring")
        }
    }
}

enum IndicatorColorMode: String, Codable, CaseIterable, Sendable {
    case usage, monochrome, accent

    var title: String {
        switch self {
        case .usage: return L("Usage colors")
        case .monochrome: return L("Monochrome")
        case .accent: return L("Accent color")
        }
    }
}

enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    var title: String { L(rawValue.capitalized) }
}

enum ResetTimeDisplay: String, Codable, CaseIterable, Sendable {
    case resetTime, countdown, both

    var title: String {
        switch self {
        case .resetTime: return L("Reset time")
        case .countdown: return L("Time remaining")
        case .both: return L("Both")
        }
    }
}
