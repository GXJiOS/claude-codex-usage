import XCTest
@testable import QuotaBar

final class CadenceThresholdsTests: XCTestCase {
    func testBoundariesMapToCadences() {
        let thresholds = CadenceThresholds.default
        XCTAssertEqual(thresholds.cadence(forTokensPerMinute: 0), .idle)
        XCTAssertEqual(thresholds.cadence(forTokensPerMinute: 499), .idle)
        XCTAssertEqual(thresholds.cadence(forTokensPerMinute: 500), .normal)
        XCTAssertEqual(thresholds.cadence(forTokensPerMinute: 11_999), .normal)
        XCTAssertEqual(thresholds.cadence(forTokensPerMinute: 12_000), .fast)
        XCTAssertEqual(thresholds.cadence(forTokensPerMinute: 24_999), .fast)
        XCTAssertEqual(thresholds.cadence(forTokensPerMinute: 25_000), .standing)
        XCTAssertEqual(thresholds.cadence(forTokensPerMinute: 1_000_000), .standing)
    }

    func testOutOfOrderBoundariesFallBackToDefaults() {
        let broken = CadenceThresholds(normalFrom: 90_000, fastFrom: 100, standingFrom: 5)
        XCTAssertEqual(broken, .default)
    }
}

final class TranscriptRateSamplerTests: XCTestCase {
    private var root: URL!
    private var claudeDir: URL!
    private var codexDir: URL!
    private var sampler: TranscriptRateSampler!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UsageRateTests-\(UUID().uuidString)", isDirectory: true)
        claudeDir = root.appendingPathComponent("claude", isDirectory: true)
        codexDir = root.appendingPathComponent("codex", isDirectory: true)
        for dir in [claudeDir!, codexDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        sampler = TranscriptRateSampler(directories: [.claude: claudeDir, .codex: codexDir])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func append(_ line: String, to file: URL) throws {
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: file)
        }
    }

    private func claudeLine(id: String, input: Int, output: Int, cacheCreation: Int, cacheRead: Int) -> String {
        """
        {"type":"assistant","timestamp":"2026-09-15T02:37:33.294Z","message":{"id":"\(id)","usage":\
        {"input_tokens":\(input),"output_tokens":\(output),\
        "cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    private func codexLine(total: Int, cached: Int) -> String {
        """
        {"timestamp":"2026-09-15T02:37:33.294Z","payload":{"type":"token_count","info":\
        {"total_token_usage":{"total_tokens":\(total),"cached_input_tokens":\(cached),\
        "input_tokens":\(total - 1000),"output_tokens":1000}}}}
        """
    }

    /// History already on disk is the baseline, not present-moment work.
    func testExistingContentIsNotCountedAsFreshWork() async throws {
        let file = claudeDir.appendingPathComponent("old.jsonl")
        try append(claudeLine(id: "a", input: 100, output: 900, cacheCreation: 0, cacheRead: 0), to: file)
        let first = await sampler.drainTokens()
        XCTAssertEqual(first[.claude], 0)
    }

    func testClaudeCountsAppendedTokensAndIgnoresCacheReads() async throws {
        let file = claudeDir.appendingPathComponent("session.jsonl")
        try append(claudeLine(id: "seed", input: 1, output: 1, cacheCreation: 0, cacheRead: 0), to: file)
        _ = await sampler.drainTokens()

        // 2 + 212 + 536 effective, against 431_076 cache reads that must not count.
        try append(claudeLine(id: "msg1", input: 2, output: 212, cacheCreation: 536, cacheRead: 431_076), to: file)
        let drained = await sampler.drainTokens()
        XCTAssertEqual(drained[.claude], 750)
    }

    /// A streamed message is rewritten with growing usage; only its growth counts.
    func testClaudeStreamingRewritesCountOnlyOnce() async throws {
        let file = claudeDir.appendingPathComponent("stream.jsonl")
        try append(claudeLine(id: "seed", input: 1, output: 1, cacheCreation: 0, cacheRead: 0), to: file)
        _ = await sampler.drainTokens()

        try append(claudeLine(id: "msg1", input: 10, output: 100, cacheCreation: 0, cacheRead: 0), to: file)
        let first = await sampler.drainTokens()
        XCTAssertEqual(first[.claude], 110)

        try append(claudeLine(id: "msg1", input: 10, output: 260, cacheCreation: 0, cacheRead: 0), to: file)
        let second = await sampler.drainTokens()
        XCTAssertEqual(second[.claude], 160, "only the 160 of growth counts, not the full 270")
    }

    /// Codex totals are cumulative per session, so consecutive events are differences.
    func testCodexCumulativeTotalsBecomeDeltas() async throws {
        let file = codexDir.appendingPathComponent("rollout.jsonl")
        try append(codexLine(total: 1_000_000, cached: 900_000), to: file)
        _ = await sampler.drainTokens()

        try append(codexLine(total: 1_050_000, cached: 930_000), to: file)
        let drained = await sampler.drainTokens()
        // effective went 100_000 -> 120_000
        XCTAssertEqual(drained[.codex], 20_000, "the first append after launch must already count")
    }

    /// A record still being written is left for the next sample rather than dropped.
    func testPartialLineIsDeferredUntilComplete() async throws {
        let file = codexDir.appendingPathComponent("partial.jsonl")
        try append(codexLine(total: 1_000, cached: 0), to: file)
        _ = await sampler.drainTokens()

        let full = codexLine(total: 5_000, cached: 0)
        let split = full.index(full.startIndex, offsetBy: 40)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(full[full.startIndex..<split].utf8))
        try handle.close()

        let midWrite = await sampler.drainTokens()
        XCTAssertEqual(midWrite[.codex], 0, "half a line carries no usable total")

        try append(String(full[split...]), to: file)
        let completed = await sampler.drainTokens()
        XCTAssertEqual(completed[.codex], 4_000)
    }
}

final class RateWindowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testEmptyWindowIsIdle() {
        let window = RateWindow(startedAt: start)
        XCTAssertEqual(window.tokensPerMinute(at: start.addingTimeInterval(120)), 0)
    }

    /// A full minute of observation reports the window total as-is.
    func testSettledWindowSumsItsSamples() {
        var window = RateWindow(startedAt: start)
        window.add(3_000, at: start.addingTimeInterval(60))
        window.add(4_000, at: start.addingTimeInterval(90))
        XCTAssertEqual(window.tokensPerMinute(at: start.addingTimeInterval(90)), 7_000)
    }

    /// Work seen in the first seconds is scaled to a minute rather than under-reported.
    func testPartialWindowIsScaledUp() {
        var window = RateWindow(startedAt: start)
        window.add(2_000, at: start.addingTimeInterval(5))
        // Below the 15s floor the divisor stays at 15s: 2000 * 60 / 15.
        XCTAssertEqual(window.tokensPerMinute(at: start.addingTimeInterval(5)), 8_000)
        XCTAssertEqual(window.tokensPerMinute(at: start.addingTimeInterval(30)), 4_000)
    }

    func testSamplesLeaveTheWindowAfterAMinute() {
        var window = RateWindow(startedAt: start)
        window.add(5_000, at: start.addingTimeInterval(60))
        XCTAssertEqual(window.tokensPerMinute(at: start.addingTimeInterval(60)), 5_000)
        window.add(0, at: start.addingTimeInterval(121))
        XCTAssertEqual(window.tokensPerMinute(at: start.addingTimeInterval(121)), 0, "the old burst has aged out")
    }
}
