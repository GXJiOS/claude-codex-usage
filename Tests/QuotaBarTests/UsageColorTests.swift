import AppKit
import XCTest
@testable import QuotaBar

final class UsageColorTests: XCTestCase {
    func testDefaultBoundariesPreserveCurrentColors() {
        let thresholds = UsageColorThresholds.default
        XCTAssertEqual(thresholds.yellowFrom, 50)
        XCTAssertEqual(thresholds.redFrom, 80)
        for percent in [0.0, 49, 49.999] {
            XCTAssertEqual(UsageColor.forUsed(percent, thresholds: thresholds), .systemGreen)
        }
        for percent in [50.0, 79, 79.999] {
            XCTAssertEqual(UsageColor.forUsed(percent, thresholds: thresholds), .systemYellow)
        }
        for percent in [80.0, 100] {
            XCTAssertEqual(UsageColor.forUsed(percent, thresholds: thresholds), .systemRed)
        }
    }

    func testCustomBoundariesApplyAtExactPercentages() {
        let thresholds = UsageColorThresholds(yellowFrom: 30, redFrom: 90)
        XCTAssertEqual(UsageColor.forUsed(29.999, thresholds: thresholds), .systemGreen)
        XCTAssertEqual(UsageColor.forUsed(30, thresholds: thresholds), .systemYellow)
        XCTAssertEqual(UsageColor.forUsed(89.999, thresholds: thresholds), .systemYellow)
        XCTAssertEqual(UsageColor.forUsed(90, thresholds: thresholds), .systemRed)
        XCTAssertEqual(UsageColor.forUsed(100, thresholds: thresholds), .systemRed)
        let narrow = UsageColorThresholds(yellowFrom: 99, redFrom: 100)
        XCTAssertEqual(UsageColor.forUsed(98.9, thresholds: narrow), .systemGreen)
        XCTAssertEqual(UsageColor.forUsed(99, thresholds: narrow), .systemYellow)
        XCTAssertEqual(UsageColor.forUsed(100, thresholds: narrow), .systemRed)
    }

    func testInvalidBoundsRecoverToDefaults() throws {
        for (yellow, red) in [(0, 80), (-1, 80), (50, 50), (90, 80), (50, 101), (100, 100)] {
            XCTAssertEqual(UsageColorThresholds(yellowFrom: yellow, redFrom: red), .default)
            let data = try JSONSerialization.data(withJSONObject: ["yellowFrom": yellow, "redFrom": red])
            XCTAssertEqual(try JSONDecoder().decode(UsageColorThresholds.self, from: data), .default)
        }
    }

    func testMissingOrMalformedNewSettingsPreserveOtherPreferences() throws {
        var settings = Settings.default
        settings.language = .english
        settings.theme = .dark
        settings.menuBarStyle = .percentageBadge
        settings.refreshInterval = 600
        settings.historyRetentionDays = 365
        settings.notificationThresholds = [42, 90]
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var missing = original
        missing.removeValue(forKey: "usageColorThresholds")
        var malformed = original
        malformed["usageColorThresholds"] = ["yellowFrom": "invalid", "redFrom": 80]
        var reversed = original
        reversed["usageColorThresholds"] = ["yellowFrom": 90, "redFrom": 40]
        for json in [missing, malformed, reversed] {
            let decoded = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded, settings)
        }
    }

    func testSavedThresholdsReloadAndResetIndependently() throws {
        let suite = "QuotaBarColorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = Settings.default
        settings.language = .english
        settings.menuBarStyle = .bar
        settings.notificationThresholds = [70, 95]
        settings.usageColorThresholds = UsageColorThresholds(yellowFrom: 25, redFrom: 65)
        settings.save(to: defaults)
        var reloaded = Settings.load(from: defaults)
        XCTAssertEqual(reloaded, settings)
        reloaded.usageColorThresholds = .default
        reloaded.save(to: defaults)
        let restored = Settings.load(from: defaults)
        XCTAssertEqual(restored.usageColorThresholds, .default)
        XCTAssertEqual(restored.notificationThresholds, [70, 95])
        XCTAssertEqual(restored.menuBarStyle, .bar)
        XCTAssertEqual(restored.language, .english)
    }

    func testRendererHonorsCustomThresholdsAndColorMode() {
        let thresholds = UsageColorThresholds(yellowFrom: 20, redFrom: 60)
        XCTAssertEqual(StatusTitleImage.color(used: 19, mode: .usage, thresholds: thresholds), .systemGreen)
        XCTAssertEqual(StatusTitleImage.color(used: 20, mode: .usage, thresholds: thresholds), .systemOrange)
        XCTAssertEqual(StatusTitleImage.color(used: 60, mode: .usage, thresholds: thresholds), .systemRed)
        XCTAssertEqual(StatusTitleImage.color(used: 90, mode: .monochrome, thresholds: thresholds), .labelColor)
        XCTAssertEqual(StatusTitleImage.color(used: 90, mode: .accent, thresholds: thresholds), .controlAccentColor)
    }
}
