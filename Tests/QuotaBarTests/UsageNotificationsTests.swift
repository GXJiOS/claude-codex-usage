import XCTest
import AppKit
@testable import QuotaBar

final class UsageNotificationsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private var settings: Settings {
        var settings = Settings.default
        settings.notificationsEnabled = true
        return settings
    }

    private func snapshot(_ used: Double, weekly: Double? = nil, at: Date? = nil,
                          reset: Date? = nil, source: String? = nil, account: String = "one@example.com") -> UsageSnapshot {
        let date = at ?? now
        return UsageSnapshot(session: UsageWindow(usedPercent: used, resetsAt: reset ?? now.addingTimeInterval(3600)),
                             weekly: weekly.map { UsageWindow(usedPercent: $0, resetsAt: now.addingTimeInterval(604800)) },
                             planLabel: nil, accountLabel: account, fetchedAt: date, sourceNote: source)
    }

    func testHighestThresholdThenNextCrossingAlertsOnce() {
        var policy = UsageNotificationPolicy()
        XCTAssertTrue(policy.evaluate(provider: .claude, snapshot: snapshot(74), settings: settings, now: now).isEmpty)
        let first = policy.evaluate(provider: .claude, snapshot: snapshot(91), settings: settings, now: now)
        XCTAssertEqual(first.map(\.threshold), [90])
        policy.markDelivered(first[0])
        XCTAssertTrue(policy.evaluate(provider: .claude, snapshot: snapshot(94), settings: settings, now: now).isEmpty)
        let next = policy.evaluate(provider: .claude, snapshot: snapshot(96), settings: settings, now: now)
        XCTAssertEqual(next.map(\.threshold), [95])
        policy.markDelivered(next[0])
        XCTAssertTrue(policy.evaluate(provider: .claude, snapshot: snapshot(81), settings: settings, now: now).isEmpty)
    }

    func testPlatformsWindowsAndAccountsAreIndependent() {
        var policy = UsageNotificationPolicy()
        let first = policy.evaluate(provider: .claude, snapshot: snapshot(91, weekly: 96), settings: settings, now: now)
        XCTAssertEqual(first.map(\.window), ["Session", "Weekly"])
        first.forEach { policy.markDelivered($0) }
        XCTAssertEqual(policy.evaluate(provider: .codex, snapshot: snapshot(91), settings: settings, now: now).count, 1)
        XCTAssertEqual(policy.evaluate(provider: .claude, snapshot: snapshot(91, account: "two@example.com"), settings: settings, now: now).count, 1)
    }

    func testSuccessfulDeliverySurvivesRestart() throws {
        var policy = UsageNotificationPolicy()
        let event = try XCTUnwrap(policy.evaluate(provider: .codex, snapshot: snapshot(97), settings: settings, now: now).first)
        policy.markDelivered(event)
        var restored = try JSONDecoder().decode(UsageNotificationPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertTrue(restored.evaluate(provider: .codex, snapshot: snapshot(98), settings: settings, now: now).isEmpty)
    }

    func testFailedDeliveryCanRetry() {
        var policy = UsageNotificationPolicy()
        let first = policy.evaluate(provider: .codex, snapshot: snapshot(80), settings: settings, now: now)
        let retry = policy.evaluate(provider: .codex, snapshot: snapshot(80), settings: settings, now: now)
        XCTAssertEqual(first, retry)
        XCTAssertEqual(retry.count, 1)
    }

    func testResetBetweenSamplesRearmsEvenWhenUsageIsAlreadyNonzero() {
        var policy = UsageNotificationPolicy()
        let first = policy.evaluate(provider: .claude, snapshot: snapshot(96), settings: settings, now: now)
        first.forEach { policy.markDelivered($0) }
        let later = now.addingTimeInterval(3700)
        let reset = later.addingTimeInterval(18000)
        let resetEvents = policy.evaluate(provider: .claude, snapshot: snapshot(12, at: later, reset: reset), settings: settings, now: later)
        XCTAssertEqual(resetEvents.count, 1)
        XCTAssertNil(resetEvents[0].threshold)
        policy.markDelivered(resetEvents[0])
        XCTAssertTrue(policy.evaluate(provider: .claude, snapshot: snapshot(13, at: later, reset: reset), settings: settings, now: later).isEmpty)
        let next = policy.evaluate(provider: .claude, snapshot: snapshot(76, at: later, reset: reset), settings: settings, now: later)
        XCTAssertEqual(next.map(\.threshold), [75])
    }

    func testCorrectedFutureResetDateDoesNotCreateNewCycle() {
        var policy = UsageNotificationPolicy()
        policy.evaluate(provider: .claude, snapshot: snapshot(96), settings: settings, now: now).forEach { policy.markDelivered($0) }
        let events = policy.evaluate(provider: .claude, snapshot: snapshot(96, reset: now.addingTimeInterval(7200)), settings: settings, now: now)
        XCTAssertTrue(events.isEmpty)
    }

    func testFallbackStaleInvalidAndDisabledInputsNeverNotify() {
        var policy = UsageNotificationPolicy()
        XCTAssertTrue(policy.evaluate(provider: .codex, snapshot: snapshot(96, source: "session log"), settings: settings, now: now).isEmpty)
        XCTAssertTrue(policy.evaluate(provider: .codex, snapshot: snapshot(96, at: now.addingTimeInterval(-7200)), settings: settings, now: now).isEmpty)
        XCTAssertTrue(policy.evaluate(provider: .codex, snapshot: snapshot(.nan), settings: settings, now: now).isEmpty)
        XCTAssertTrue(policy.evaluate(provider: .codex, snapshot: snapshot(101), settings: settings, now: now).isEmpty)
        XCTAssertTrue(policy.evaluate(provider: .codex, snapshot: snapshot(96), settings: .default, now: now).isEmpty)
        XCTAssertTrue(policy.states.isEmpty)
    }

    func testOlderResponseCannotRollBackNotificationCycle() {
        var policy = UsageNotificationPolicy()
        let later = now.addingTimeInterval(20)
        let fresh = policy.evaluate(provider: .claude, snapshot: snapshot(95, at: later), settings: settings, now: later)
        fresh.forEach { policy.markDelivered($0) }
        XCTAssertTrue(policy.evaluate(provider: .claude, snapshot: snapshot(76), settings: settings, now: later).isEmpty)
        XCTAssertEqual(policy.states.values.first?.used, 95)
    }

    func testCustomThresholdsAndDisabledResetAlerts() {
        var custom = settings
        custom.notificationThresholds = [0, 42, 42, 110]
        custom.notifyOnReset = false
        var policy = UsageNotificationPolicy()
        let events = policy.evaluate(provider: .codex, snapshot: snapshot(43), settings: custom, now: now)
        XCTAssertEqual(events.map(\.threshold), [42])
        events.forEach { policy.markDelivered($0) }
        let later = now.addingTimeInterval(3700)
        XCTAssertTrue(policy.evaluate(provider: .codex, snapshot: snapshot(0, at: later, reset: later.addingTimeInterval(18000)), settings: custom, now: later).isEmpty)
    }

    func testHistoryExportMatchesProviderAndVisibleTimeRange() throws {
        let records = [
            HistoryRecord(at: now.addingTimeInterval(-60), provider: "claude", session: 12, weekly: nil, tokensToday: 100),
            HistoryRecord(at: now, provider: "codex", session: 22, weekly: 40, tokensToday: 200),
            HistoryRecord(at: now.addingTimeInterval(120), provider: "claude", session: 33, weekly: 50, tokensToday: 300)
        ]
        let selection = HistorySelection(provider: .claude, start: now.addingTimeInterval(-120), end: now)
        let data = try selection.export(records, asCSV: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([HistoryRecord].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].session, 12)
        XCTAssertNil(decoded[0].weekly)
        let csv = String(decoding: try selection.export(records, asCSV: true), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"claude\",\"12.0\",\"\",\"100\""))
        XCTAssertFalse(csv.contains("codex"))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 3)
    }

    func testExistingRefreshAndRetentionPreferencesArePreserved() throws {
        let name = "QuotaBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(600.0, forKey: "refreshInterval")
        defaults.set(365, forKey: "historyRetentionDays")
        var loaded = Settings.load(from: defaults)
        XCTAssertEqual(loaded.refreshInterval, 600)
        XCTAssertEqual(loaded.historyRetentionDays, 365)
        loaded.menuBarStyle = .battery
        loaded.timeDisplay = .countdown
        loaded.notificationThresholds = [80, 95]
        loaded.save(to: defaults)
        XCTAssertEqual(Settings.load(from: defaults), loaded)
    }

    @MainActor
    func testPreviewRefreshIsIsolatedFromProvidersAndHistory() async {
        let statuses = PreviewData.statuses(state: "fallback", now: now)
        let store = UsageStore(providers: [], preview: statuses)
        var deliveries = 0
        store.onFreshSnapshot = { _, _ in deliveries += 1 }
        await store.refresh(force: true)
        XCTAssertEqual(deliveries, 0)
        XCTAssertNil(store.lastRefresh)
        XCTAssertNotNil(store.statuses[.codex]?.snapshot?.sourceNote)
        XCTAssertEqual(store.statuses[.claude]?.snapshot?.session?.usedPercent, 39)
    }
}

final class LocalizationTests: XCTestCase {
    private var originalLanguage = AppLanguage.english

    override func setUp() {
        super.setUp()
        originalLanguage = L10n.language
    }

    override func tearDown() {
        L10n.language = originalLanguage
        super.tearDown()
    }

    func testLanguageDefaultsAndSavedChoice() throws {
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["zh-TW", "en"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["ja"]), .english)
        let name = "QuotaBarLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = Settings.default
        settings.language = .simplifiedChinese
        settings.save(to: defaults)
        XCTAssertEqual(Settings.load(from: defaults).language, .simplifiedChinese)
        XCTAssertEqual(AppLanguage.load(from: defaults), .simplifiedChinese)
        settings.language = .english
        settings.save(to: defaults)
        XCTAssertEqual(Settings.load(from: defaults).language, .english)
        XCTAssertEqual(AppLanguage.load(from: defaults), .english)
    }

    func testPreferencesBeforeLanguageFeatureKeepAllExistingChoices() throws {
        var settings = Settings.default
        settings.refreshInterval = 600
        settings.historyRetentionDays = 365
        settings.menuBarStyle = .battery
        settings.colorMode = .accent
        settings.theme = .dark
        settings.notificationThresholds = [42, 90]
        settings.notificationsEnabled = true
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "language")
        let restored = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        settings.language = .systemDefault()
        XCTAssertEqual(restored, settings)
    }

    func testCompactStyleMigratesToBadgeWithoutResettingPreferences() throws {
        var settings = Settings.default
        settings.language = .english
        settings.theme = .dark
        settings.refreshInterval = 600
        settings.historyRetentionDays = 365
        settings.notificationThresholds = [42, 90]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json["menuBarStyle"] = "compact"
        let restored = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        settings.menuBarStyle = .percentageBadge
        XCTAssertEqual(restored, settings)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertEqual(saved["menuBarStyle"] as? String, "percentageBadge")
        XCTAssertNil(MenuBarStyle(rawValue: "compact"))
        XCTAssertEqual(MenuBarStyle.allCases.count, 5)
    }

    func testCatalogsHaveMatchingKeysAndFormatArguments() throws {
        func catalog(_ language: AppLanguage) throws -> [String: String] {
            let url = try XCTUnwrap(L10n.bundle(for: language).url(forResource: "Localizable", withExtension: "strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let en = try catalog(.english)
        let zh = try catalog(.simplifiedChinese)
        XCTAssertGreaterThan(en.count, 200)
        XCTAssertEqual(Set(en.keys), Set(zh.keys))
        let placeholders = try NSRegularExpression(pattern: "(?<!%)%(?!%)(?:[0-9]+\\$)?([@d])")
        func arguments(_ text: String) -> [String] {
            let value = text as NSString
            return placeholders.matches(in: text, range: NSRange(location: 0, length: value.length))
                .map { value.substring(with: $0.range(at: 1)) }.sorted()
        }
        for (key, value) in en { XCTAssertEqual(arguments(value), arguments(zh[key] ?? ""), "Format mismatch: \(key)") }
        XCTAssertEqual(L10n.text("App Settings", language: .simplifiedChinese), "应用设置")
        XCTAssertEqual(L10n.text("Unknown diagnostic text", language: .simplifiedChinese), "Unknown diagnostic text")
    }

    func testLanguageSwitchImmediatelyUpdatesUnitsDatesAndErrors() {
        let status = ProviderStatus(errorMessage: "expired",
                                    providerError: .tokenExpired("Run `codex` once so it refreshes the login."))
        L10n.language = .english
        XCTAssertEqual(Format.tokens(1_234_000), "1.2M")
        XCTAssertTrue(status.localizedErrorMessage?.contains("Token expired") == true)
        let englishDuration = Format.countdown(3660)
        L10n.language = .simplifiedChinese
        XCTAssertEqual(Format.tokens(1_234_000), "123万")
        XCTAssertTrue(Format.shortDate(Date()).contains("月"))
        XCTAssertTrue(status.localizedErrorMessage?.contains("登录已过期") == true)
        XCTAssertNotEqual(Format.countdown(3660), englishDuration)
        XCTAssertEqual(L("%d minutes", 5), "5 分钟")
    }

    func testNotificationTranslationPreservesDeduplicationIdentity() throws {
        let now = Date()
        var settings = Settings.default
        settings.notificationsEnabled = true
        let snapshot = UsageSnapshot(session: UsageWindow(usedPercent: 91, resetsAt: now.addingTimeInterval(3600)),
                                     weekly: nil, planLabel: nil, fetchedAt: now, sourceNote: nil)
        var policy = UsageNotificationPolicy()
        L10n.language = .english
        let event = try XCTUnwrap(policy.evaluate(provider: .codex, snapshot: snapshot, settings: settings, now: now).first)
        let id = event.id
        XCTAssertTrue(event.body.contains("91% of your session quota"))
        policy.markDelivered(event)
        L10n.language = .simplifiedChinese
        XCTAssertEqual(event.id, id)
        XCTAssertTrue(event.title.contains("会话用量提醒"))
        XCTAssertTrue(event.body.contains("会话额度已使用 91%"))
        XCTAssertTrue(policy.evaluate(provider: .codex, snapshot: snapshot, settings: settings, now: now).isEmpty)
    }

    @MainActor
    func testChangingLanguageKeepsSelectedPageAndProvider() {
        _ = NSApplication.shared
        let model = SettingsModel(persistChanges: false)
        model.page = .app
        model.selectedProvider = .codex
        model.settings.language = .simplifiedChinese
        XCTAssertEqual(L("Appearance"), "外观")
        XCTAssertEqual(model.page, .app)
        XCTAssertEqual(model.selectedProvider, .codex)
        model.settings.language = .english
        XCTAssertEqual(L("Appearance"), "Appearance")
    }
}
