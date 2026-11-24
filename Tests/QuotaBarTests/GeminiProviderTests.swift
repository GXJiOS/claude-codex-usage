import AppKit
import XCTest
@testable import QuotaBar

final class GeminiProviderTests: XCTestCase {
    /// Trimmed from a real `agy -p "/usage" --output-format json` reply.
    private func usageJSON(geminiFiveHour: String = #""remaining_fraction": 1,"#, status: String = "SUCCESS") -> Data {
        Data("""
        {"conversation_id": "", "status": "\(status)", "response": "Gemini Models\\tWeekly Limit Remaining\\t88%",
         "command": {"name": "usage", "data": {"groups": [
          {"name": "Gemini Models", "buckets": [
            {"id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.88, "reset_time": "2026-11-21T02:50:58Z"},
            {"id": "gemini-5h", "window": "5h", \(geminiFiveHour) "reset_time": "2026-11-16T07:00:41Z"}]},
          {"name": "Claude and GPT models", "buckets": [
            {"id": "3p-weekly", "window": "weekly", "remaining_fraction": 0.10, "reset_time": "2026-11-23T01:27:46Z"},
            {"id": "3p-5h", "window": "5h", "remaining_fraction": 0.20, "reset_time": "2026-11-16T06:27:46Z"}]},
          {"name": "Gemini 4 Argon", "buckets": [
            {"id": "gemini-argon-wtu-weekly", "window": "weekly", "remaining_fraction": 0.95, "reset_time": "2026-11-23T01:24:24Z"}]}
         ]}}}
        """.utf8)
    }

    func testMapsGeminiWindowsArgonAndClaudeGPTRows() throws {
        let snapshot = try GeminiProvider.snapshot(from: usageJSON(), accountLabel: "g@example.test", now: Date())
        XCTAssertEqual(try XCTUnwrap(snapshot.session?.usedPercent), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.weekly?.usedPercent), 12, accuracy: 0.001)
        XCTAssertEqual(snapshot.session?.resetsAt, ISO8601DateFormatter().date(from: "2026-11-16T07:00:41Z"))
        XCTAssertEqual(snapshot.extras.map(\.label), ["Argon", "Claude/GPT session", "Claude/GPT weekly"])
        XCTAssertEqual(snapshot.extras.map { ($0.window.usedPercent * 1000).rounded() / 1000 }, [5, 80, 90])
        XCTAssertEqual(snapshot.extras[1].window.resetsAt, ISO8601DateFormatter().date(from: "2026-11-16T06:27:46Z"))
        XCTAssertEqual(snapshot.accountLabel, "g@example.test")
        XCTAssertNil(snapshot.tokensToday)
    }

    func testClaudeGPTRowLabelsTranslateAndModelNamesStay() {
        XCTAssertEqual(L10n.text("Claude/GPT session", language: .simplifiedChinese), "Claude/GPT 会话")
        XCTAssertEqual(L10n.text("Claude/GPT weekly", language: .simplifiedChinese), "Claude/GPT 每周")
        XCTAssertEqual(L10n.text("Claude/GPT weekly", language: .english), "Claude/GPT weekly")
        XCTAssertEqual(L10n.text("Argon", language: .simplifiedChinese), "Argon")
    }

    func testAccountEmailComesFromTheAuthLogLine() {
        let log = """
        I1124 16:51:49.100000       1 server.go:10] starting
        I1124 16:51:49.206064       1 server_oauth.go:221] applyAuthResult: email=g@example.test, authMethod=consumer, quotaProject=
        """
        XCTAssertEqual(GeminiProvider.accountEmail(inLog: log), "g@example.test")
        XCTAssertNil(GeminiProvider.accountEmail(inLog: "applyAuthResult: email=, authMethod=consumer"))
        XCTAssertNil(GeminiProvider.accountEmail(inLog: "no auth line"))
    }

    func testMissingRemainingFractionMeansSpent() throws {
        let snapshot = try GeminiProvider.snapshot(from: usageJSON(geminiFiveHour: ""), now: Date())
        XCTAssertEqual(try XCTUnwrap(snapshot.session?.usedPercent), 100, accuracy: 0.001)
        XCTAssertEqual(ProviderKind.gemini.menuBarWindow(in: snapshot)?.usedPercent, 100)
    }

    func testFailedCommandSurfacesItsStatus() {
        XCTAssertThrowsError(try GeminiProvider.snapshot(from: usageJSON(status: "ERROR"), now: Date())) { error in
            guard case ProviderError.decoding(let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("ERROR"))
        }
    }

    func testReplyWithoutGeminiBucketsThrows() {
        let data = Data(#"{"status": "SUCCESS", "command": {"data": {"groups": []}}}"#.utf8)
        XCTAssertThrowsError(try GeminiProvider.snapshot(from: data, now: Date()))
    }

    func testRawFetchUsesInjectedCommand() async throws {
        let provider = GeminiProvider(runUsage: { [json = usageJSON()] in
            GeminiProvider.UsageReply(data: json, accountEmail: "g@example.test")
        })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.extras.count, 3)
        XCTAssertEqual(snapshot.accountLabel, "g@example.test")
        let raw = try await provider.fetchRawJSON()
        XCTAssertTrue(raw.contains("gemini-argon-wtu-weekly"))
    }

    /// A stand-in `agy` that writes `logLine` to its `--log-file` (recording that path in
    /// `log-path.txt` next to it), prints `body` and exits with `code`.
    private func fakeCLI(printing body: Data, exitCode code: Int32, logLine: String = "") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appendingPathComponent("usage.json")
        try body.write(to: payload)
        let script = directory.appendingPathComponent("agy")
        try """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          if [ "$1" = "--log-file" ]; then printf '%s\\n' '\(logLine)' > "$2"; printf '%s' "$2" > '\(directory.path)/log-path.txt'; fi
          shift
        done
        cat '\(payload.path)'
        exit \(code)

        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testCleanExitReturnsTheReplyAndAccountThenRemovesTheLog() throws {
        let cli = try fakeCLI(printing: usageJSON(), exitCode: 0,
                              logLine: "server_oauth.go:221] applyAuthResult: email=g@example.test, authMethod=consumer")
        let reply = try GeminiProvider.runCLI(executable: cli)
        XCTAssertEqual(try GeminiProvider.snapshot(from: reply.data, now: Date()).extras.count, 3)
        XCTAssertEqual(reply.accountEmail, "g@example.test")
        let logPath = try String(contentsOf: cli.deletingLastPathComponent().appendingPathComponent("log-path.txt"), encoding: .utf8)
        XCTAssertTrue(logPath.hasPrefix(FileManager.default.temporaryDirectory.path), logPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logPath), "the run's log is removed")
    }

    func testInstalledCLIReportsTheSignedInAccount() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_AGY_INTEGRATION"] == "1" else {
            throw XCTSkip("Set QUOTABAR_AGY_INTEGRATION=1 to run the installed, signed-in agy")
        }
        let reply = try GeminiProvider.runCLI()
        XCTAssertEqual(reply.accountEmail?.contains("@"), true)
        XCTAssertFalse(try GeminiProvider.snapshot(from: reply.data, now: Date()).extras.isEmpty)
    }

    func testFailedExitIsAnErrorEvenWithAReply() throws {
        let cli = try fakeCLI(printing: usageJSON(), exitCode: 7)
        XCTAssertThrowsError(try GeminiProvider.runCLI(executable: cli)) { error in
            guard case ProviderError.decoding(let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("code 7"), detail)
        }
        XCTAssertThrowsError(try GeminiProvider.runCLI(executable: fakeCLI(printing: Data(), exitCode: 0)))
        XCTAssertThrowsError(try GeminiProvider.runCLI(executable: nil)) { error in
            guard case ProviderError.notLoggedIn = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Menu bar visibility

    func testMenuBarProvidersFollowHiddenSetAndNeverEmpty() throws {
        var settings = Settings.default
        XCTAssertEqual(settings.menuBarProviders, [.claude, .codex, .gemini])
        settings.hiddenMenuBarProviders = [.codex]
        XCTAssertEqual(settings.menuBarProviders, [.claude, .gemini])
        settings.hiddenMenuBarProviders = Set(ProviderKind.allCases)
        XCTAssertEqual(settings.menuBarProviders, ProviderKind.allCases)

        settings.hiddenMenuBarProviders = [.gemini]
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.hiddenMenuBarProviders, [.gemini])
    }

    func testStoredPreferencesWithoutOrWithUnknownProvidersDecode() throws {
        let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"showLabels": false}"#.utf8))
        XCTAssertEqual(legacy.hiddenMenuBarProviders, [])
        let unknown = try JSONDecoder().decode(Settings.self, from: Data(#"{"hiddenMenuBarProviders": ["codex", "retired"]}"#.utf8))
        XCTAssertEqual(unknown.hiddenMenuBarProviders, [.codex])
    }

    @MainActor
    func testMenuBarImageWidthTracksShownProviders() {
        let statuses = PreviewData.statuses()
        func width(hiding hidden: Set<ProviderKind>) -> CGFloat {
            var settings = Settings.default
            settings.menuBarStyle = .ring
            settings.showLabels = false
            settings.hiddenMenuBarProviders = hidden
            return StatusTitleImage.layout(statuses: statuses, settings: settings, mode: .used, withRiders: false).size.width
        }
        let one = width(hiding: [.codex, .gemini])
        let two = width(hiding: [.gemini])
        let three = width(hiding: [])
        // Ring columns are 20pt with a 12pt gap between neighbours.
        XCTAssertEqual(one, 20)
        XCTAssertEqual(two, 52)
        XCTAssertEqual(three, 84)
    }

    // MARK: - Notifications

    /// An untouched Gemini 5h bucket reports "now + 5h" on every poll, so its reset date
    /// slides forward without a real window change.
    func testSlidingResetOfUntouchedBucketRaisesNoAlerts() {
        var settings = Settings.default
        settings.notificationsEnabled = true
        settings.notifyOnReset = true
        var policy = UsageNotificationPolicy()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func snapshot(used: Double, at: Date, reset: Date) -> UsageSnapshot {
            UsageSnapshot(session: UsageWindow(usedPercent: used, resetsAt: reset), weekly: nil,
                          planLabel: nil, fetchedAt: at, sourceNote: nil)
        }
        for poll in 0..<6 {
            let at = start.addingTimeInterval(Double(poll) * 300)
            let events = policy.evaluate(provider: .gemini, snapshot: snapshot(used: 0, at: at, reset: at.addingTimeInterval(5 * 3600)),
                                         settings: settings, now: at)
            XCTAssertTrue(events.isEmpty, "poll \(poll)")
        }
        XCTAssertEqual(policy.states.count, 1)

        // First use pins the reset date; crossing a threshold alerts once, with no reset alert.
        let firstUse = start.addingTimeInterval(1_800)
        let pinned = firstUse.addingTimeInterval(5 * 3600)
        let used = policy.evaluate(provider: .gemini, snapshot: snapshot(used: 80, at: firstUse, reset: pinned),
                                   settings: settings, now: firstUse)
        XCTAssertEqual(used.map(\.threshold), [75])
    }
}
