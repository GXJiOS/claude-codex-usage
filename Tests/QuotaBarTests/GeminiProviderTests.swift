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

    func testMapsGeminiWindowsAndArgonRow() throws {
        let snapshot = try GeminiProvider.snapshot(from: usageJSON(), now: Date())
        XCTAssertEqual(try XCTUnwrap(snapshot.session?.usedPercent), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.weekly?.usedPercent), 12, accuracy: 0.001)
        XCTAssertEqual(snapshot.session?.resetsAt, ISO8601DateFormatter().date(from: "2026-11-16T07:00:41Z"))
        XCTAssertEqual(snapshot.extras.map(\.label), ["Argon"], "the Claude and GPT group stays out")
        XCTAssertEqual(try XCTUnwrap(snapshot.extras.first?.window.usedPercent), 5, accuracy: 0.001)
        XCTAssertNil(snapshot.tokensToday)
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
        let provider = GeminiProvider(runUsage: { [json = usageJSON()] in json })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.extras.count, 1)
        let raw = try await provider.fetchRawJSON()
        XCTAssertTrue(raw.contains("gemini-argon-wtu-weekly"))
    }

    /// A stand-in `agy` that prints `body` and exits with `code`.
    private func fakeCLI(printing body: Data, exitCode code: Int32) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appendingPathComponent("usage.json")
        try body.write(to: payload)
        let script = directory.appendingPathComponent("agy")
        try "#!/bin/sh\ncat '\(payload.path)'\nexit \(code)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testCleanExitReturnsTheReply() throws {
        let data = try GeminiProvider.runCLI(executable: fakeCLI(printing: usageJSON(), exitCode: 0))
        XCTAssertEqual(try GeminiProvider.snapshot(from: data, now: Date()).extras.map(\.label), ["Argon"])
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
