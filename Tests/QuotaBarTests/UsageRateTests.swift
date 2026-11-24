import SQLite3
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

/// Protobuf wire-format encoder for agy fixtures.
private enum Wire {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            let low = UInt8(value & 0x7f)
            value >>= 7
            bytes.append(value == 0 ? low : low | 0x80)
        } while value != 0
        return bytes
    }
    static func field(_ number: Int, _ value: Int) -> [UInt8] { varint(UInt64(number << 3)) + varint(UInt64(value)) }
    static func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }
    static func field(_ number: Int, _ text: String) -> [UInt8] { field(number, Array(text.utf8)) }
    static func fixed64(_ number: Int) -> [UInt8] { varint(UInt64(number << 3 | 1)) + [UInt8](repeating: 0x40, count: 8) }

    /// A `gen_metadata` row shaped like agy's, with the usage at field 1.4.
    static func generation(input: Int, output: Int, thinking: Int, cacheRead: Int = 0, step: Int? = nil) -> [UInt8] {
        var usage = field(1, 1532) + field(2, input) + field(3, output)
        if cacheRead > 0 { usage += field(5, cacheRead) }
        usage += field(6, 24) + field(7, "response-id") + field(9, thinking)
        var record = field(3, 1532) + field(4, usage) + fixed64(11) + field(19, "gemini-4-neon")
        record += field(20, field(1, "request_id") + field(2, "r-1"))
        if let step { record += field(20, field(1, "last_step_index") + field(2, String(step))) }
        return field(1, record) + field(2, "") + field(4, "trajectory")
    }

    /// A `steps` row's metadata, with the creation time at field 1.1.
    static func step(at date: Date) -> [UInt8] {
        field(1, field(1, Int(date.timeIntervalSince1970)) + field(2, 500)) + field(6, field(1, Int(date.timeIntervalSince1970)))
    }
}

/// A conversation database with agy's two tables. Rollback-journal fixtures close after every
/// write, like a conversation agy has finished with; WAL fixtures stay open like a live one.
private final class AgyDatabase {
    let url: URL
    private var db: OpaquePointer?
    private let live: Bool

    init(_ url: URL, live: Bool = false) throws {
        self.url = url
        self.live = live
        try open()
        try exec(live ? "PRAGMA journal_mode=WAL" : "PRAGMA journal_mode=DELETE")
        try exec("CREATE TABLE gen_metadata (idx integer, data blob, size integer NOT NULL DEFAULT 0, PRIMARY KEY (idx))")
        try exec("CREATE TABLE steps (idx integer, step_type integer NOT NULL DEFAULT 0, metadata blob, PRIMARY KEY (idx))")
        if !live { close() }
    }

    deinit { close() }

    func put(generation index: Int, _ blob: [UInt8]) throws {
        try write("INSERT OR REPLACE INTO gen_metadata (idx, data, size) VALUES (?1, ?2, 0)", index, blob)
    }

    func put(step index: Int, at date: Date) throws {
        try write("INSERT OR REPLACE INTO steps (idx, metadata) VALUES (?1, ?2)", index, Wire.step(at: date))
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    private func open() throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private func write(_ sql: String, _ index: Int, _ blob: [UInt8]) throws {
        if db == nil { try open() }
        defer { if !live { close() } }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(index))
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(blob.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }
}

final class AgyStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgyStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sampler(startedAt: Date) -> TranscriptRateSampler {
        TranscriptRateSampler(directories: [.gemini: dir], startedAt: startedAt)
    }

    /// Field numbers verified against `agy -p --output-format json` usage: 2293 input,
    /// 24 output, 22 thinking and 8142 cache read for the second call of a conversation.
    func testDecodesTheUsageAndStepOfACall() throws {
        let call = try XCTUnwrap(AgyStore.generation(from: Wire.generation(input: 2293, output: 24, thinking: 22,
                                                                           cacheRead: 8142, step: 7)[...]))
        XCTAssertEqual(call, AgyGeneration(input: 2293, output: 24, thinking: 22, cacheRead: 8142, stepIndex: 7))
        XCTAssertEqual(call.effective, 2339)
        XCTAssertEqual(call.total, 10_481)
        let at = Date(timeIntervalSince1970: 1_795_511_294)
        XCTAssertEqual(AgyStore.stepTime(from: Wire.step(at: at)[...]), at)
    }

    func testMalformedRowDecodesToNothing() {
        XCTAssertNil(AgyStore.generation(from: [0x0a, 0xff, 0x01][...]))
        XCTAssertNil(AgyStore.generation(from: Wire.field(1, Wire.field(3, 1532))[...]), "no usage message")
        let huge = Wire.field(1, Wire.field(4, Wire.varint(2 << 3) + Wire.varint(UInt64.max) + Wire.field(3, 5)))
        XCTAssertNil(AgyStore.generation(from: huge[...]), "an implausible count drops the row")
    }

    /// A conversation that existed before launch is a baseline; later calls count, and a
    /// rewritten newest call counts only by its growth.
    func testExistingConversationCountsOnlyNewWork() async throws {
        let database = try AgyDatabase(dir.appendingPathComponent("old.db"))
        try database.put(generation: 0, Wire.generation(input: 10_199, output: 25, thinking: 23))
        let sampler = sampler(startedAt: Date().addingTimeInterval(60))
        let baseline = await sampler.drainTokens()
        XCTAssertEqual(baseline[.gemini], 0)

        try database.put(generation: 1, Wire.generation(input: 2293, output: 24, thinking: 22, cacheRead: 8142))
        let next = await sampler.drainTokens()
        XCTAssertEqual(next[.gemini], 2339, "cache reads stay out of the rate")

        try database.put(generation: 1, Wire.generation(input: 2293, output: 124, thinking: 22, cacheRead: 8142))
        let grown = await sampler.drainTokens()
        XCTAssertEqual(grown[.gemini], 100)
        let idle = await sampler.drainTokens()
        XCTAssertEqual(idle[.gemini], 0)
    }

    func testExistingConversationWithoutCallsCountsItsFirstCall() async throws {
        let database = try AgyDatabase(dir.appendingPathComponent("empty.db"))
        let sampler = sampler(startedAt: Date().addingTimeInterval(60))
        _ = await sampler.drainTokens()
        try database.put(generation: 0, Wire.generation(input: 300, output: 20, thinking: 10))
        let drained = await sampler.drainTokens()
        XCTAssertEqual(drained[.gemini], 330)
    }

    func testConversationStartedAfterLaunchCountsItsFirstCall() async throws {
        let sampler = sampler(startedAt: Date().addingTimeInterval(-60))
        let database = try AgyDatabase(dir.appendingPathComponent("new.db"))
        try database.put(generation: 0, Wire.generation(input: 10_199, output: 25, thinking: 23))
        let drained = await sampler.drainTokens()
        XCTAssertEqual(drained[.gemini], 10_247)
    }

    /// A live session keeps its rows in the WAL; the reader must see them without writing.
    func testLiveConversationIsReadThroughItsWAL() async throws {
        let database = try AgyDatabase(dir.appendingPathComponent("live.db"), live: true)
        try database.put(generation: 0, Wire.generation(input: 100, output: 10, thinking: 0))
        let sampler = sampler(startedAt: Date().addingTimeInterval(60))
        _ = await sampler.drainTokens()
        try database.put(generation: 1, Wire.generation(input: 400, output: 50, thinking: 50))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.url.path + "-wal"))
        let drained = await sampler.drainTokens()
        XCTAssertEqual(drained[.gemini], 500)
        database.close()
    }

    func testClosedConversationIsReadWithoutCreatingFiles() throws {
        let database = try AgyDatabase(dir.appendingPathComponent("closed.db"))
        try database.put(generation: 0, Wire.generation(input: 1, output: 2, thinking: 3))
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(AgyStore.generations(in: database.url, fromIndex: 0)?.map(\.generation.effective), [6])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), before)
    }

    /// Runs one short prompt through the installed agy and expects the sampler to see it.
    func testInstalledCLIRunRegistersAsWork() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_AGY_INTEGRATION"] == "1",
              let agy = GeminiProvider.executable() else {
            throw XCTSkip("Set QUOTABAR_AGY_INTEGRATION=1 to run a prompt through the installed, signed-in agy")
        }
        let sampler = TranscriptRateSampler(directories: [.gemini: AgyStore.conversationsDir], startedAt: Date())
        _ = await sampler.drainTokens()
        // A file read makes the turn take two model calls, so the first lands while agy still runs.
        let workspace = dir.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "kiwi".write(to: workspace.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = agy
        process.arguments = ["-p", "Read note.txt with your file tool, then reply with its single word.",
                             "--log-file", "/dev/null", "--print-timeout", "100s"]
        process.currentDirectoryURL = workspace
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        var whileRunning = 0
        let launched = Date()
        while process.isRunning {
            let drained = await sampler.drainTokens()[.gemini] ?? 0
            if drained > 0 { print("agy integration: +\(drained) at \(Int(Date().timeIntervalSince(launched)))s") }
            whileRunning += drained
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        print("agy integration: exited at \(Int(Date().timeIntervalSince(launched)))s")
        let afterExit = await sampler.drainTokens()[.gemini] ?? 0
        print("agy integration: \(whileRunning) tokens while running, \(afterExit) after exit")
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertGreaterThan(whileRunning, 1_000, "calls register while the session is still open")
    }

    /// Today's total counts every token of calls whose step is dated today, cache reads included.
    func testTodayTotalUsesStepDates() throws {
        let database = try AgyDatabase(dir.appendingPathComponent("today.db"))
        let now = Date()
        let yesterday = Calendar.current.startOfDay(for: now).addingTimeInterval(-3600)
        try database.put(step: 1, at: yesterday)
        try database.put(step: 2, at: now)
        try database.put(generation: 0, Wire.generation(input: 5_000, output: 5, thinking: 5, step: 1))
        try database.put(generation: 1, Wire.generation(input: 2293, output: 24, thinking: 22, cacheRead: 8142, step: 2))
        try database.put(generation: 2, Wire.generation(input: 7, output: 7, thinking: 7))
        XCTAssertEqual(TokenLog.geminiTokensToday(conversationsDir: dir), 10_481)
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

final class TokenRateDisplayTests: XCTestCase {
    func testUnknownRateIsDistinctFromIdle() {
        XCTAssertEqual(Format.tokenRate(nil), "– token/min")
        XCTAssertEqual(Format.tokenRate(0), "0 token/min")
    }

    func testMinuteRateKeepsExactCountsInBothLanguages() {
        let original = L10n.language
        defer { L10n.language = original }
        for language in AppLanguage.allCases {
            L10n.language = language
            XCTAssertEqual(Format.tokenRate(12_800), "12,800 token/min")
            XCTAssertEqual(Format.tokenRate(999), "999 token/min")
            XCTAssertEqual(Format.tokenRate(1_234_567), "1,234,567 token/min")
        }
    }

    @MainActor
    func testProviderMinuteRatesReturnToZeroAfterWindowExpires() {
        let monitor = UsageRateMonitor(isLive: false)
        let now = Date().addingTimeInterval(RateWindow.span)
        monitor.absorb([.claude: 12_800, .codex: 3_600], at: now)
        XCTAssertEqual(Format.tokenRate(monitor.rates[.claude]), "12,800 token/min")
        XCTAssertEqual(Format.tokenRate(monitor.rates[.codex]), "3,600 token/min")

        monitor.absorb([:], at: now.addingTimeInterval(RateWindow.span))
        XCTAssertEqual(Format.tokenRate(monitor.rates[.claude]), "0 token/min")
        XCTAssertEqual(Format.tokenRate(monitor.rates[.codex]), "0 token/min")
    }
}
