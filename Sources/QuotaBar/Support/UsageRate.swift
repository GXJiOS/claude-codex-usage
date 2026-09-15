import Foundation
import Combine

/// How hard the menu bar cyclist pedals, derived from live token throughput.
enum PedalCadence: String, Sendable, CaseIterable {
    case idle, normal, fast, standing

    var title: String {
        switch self {
        case .idle: return L("Parked")
        case .normal: return L("Steady")
        case .fast: return L("Fast")
        case .standing: return L("Sprinting")
        }
    }
}

/// Boundaries in effective tokens per minute, ordered idle → normal → fast → standing.
/// The defaults come from a seven-day sample of real transcripts, where an active
/// minute sits at ~7k tokens (median), ~13k at p75 and ~22k at p90.
struct CadenceThresholds: Codable, Equatable, Sendable {
    let normalFrom: Int
    let fastFrom: Int
    let standingFrom: Int

    static let `default` = CadenceThresholds()

    init(normalFrom: Int = 500, fastFrom: Int = 12_000, standingFrom: Int = 25_000) {
        if normalFrom > 0, normalFrom < fastFrom, fastFrom < standingFrom {
            self.normalFrom = normalFrom
            self.fastFrom = fastFrom
            self.standingFrom = standingFrom
        } else {
            self.normalFrom = 500
            self.fastFrom = 12_000
            self.standingFrom = 25_000
        }
    }

    private enum CodingKeys: String, CodingKey { case normalFrom, fastFrom, standingFrom }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(normalFrom: try values.decode(Int.self, forKey: .normalFrom),
                  fastFrom: try values.decode(Int.self, forKey: .fastFrom),
                  standingFrom: try values.decode(Int.self, forKey: .standingFrom))
    }

    func cadence(forTokensPerMinute rate: Int) -> PedalCadence {
        switch rate {
        case standingFrom...: return .standing
        case fastFrom...: return .fast
        case normalFrom...: return .normal
        default: return .idle
        }
    }
}

/// Tails the transcripts both CLIs write on this Mac and reports the tokens appended
/// since the previous call. Averaging those deltas into a rate is `RateWindow`'s job.
///
/// Throughput counts input, output and cache *creation* tokens, and leaves cache reads
/// out: a single Claude request reads ~431k cached tokens against ~750 of real work, and
/// a Codex session logs 84M cached against 3M — counting them would peg every provider at
/// full speed. With cache reads excluded both providers land on the same distribution,
/// so they share one set of thresholds.
///
/// Only bytes appended since the previous sample are read, and a file first seen is
/// picked up at its current end, so history never registers as present-moment work.
actor TranscriptRateSampler {
    /// Files untouched for longer than this are not worth reopening.
    private static let activeFileWindow: TimeInterval = 10 * 60
    /// How long a streamed message id is remembered for de-duplication.
    private static let messageMemory: TimeInterval = 5 * 60
    /// Tail scanned to recover a session's running total when its file is first seen.
    private static let baselineScan = 256 * 1024

    private struct Cursor {
        var offset: UInt64 = 0
        /// Codex writes cumulative totals; the previous one turns them into deltas.
        var cumulative: Int?
        var lastSeen = Date()
    }

    private let directories: [ProviderKind: URL]
    private var cursors: [ProviderKind: [URL: Cursor]] = [:]
    /// Claude streams one line per content block of the same message, with usage growing
    /// as the response completes; only the growth of each id counts.
    private var claudeMessages: [String: (value: Int, at: Date)] = [:]

    init(directories: [ProviderKind: URL] = TranscriptRateSampler.defaultDirectories()) {
        self.directories = directories
    }

    static func defaultDirectories() -> [ProviderKind: URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".codex", isDirectory: true)
        return [.claude: claudeHome.appendingPathComponent("projects", isDirectory: true),
                .codex: codexHome.appendingPathComponent("sessions", isDirectory: true)]
    }

    /// Effective tokens each provider has written since the previous call.
    func drainTokens(now: Date = Date()) -> [ProviderKind: Int] {
        var drained: [ProviderKind: Int] = [:]
        for kind in ProviderKind.allCases {
            drained[kind] = drain(kind, now: now)
        }
        claudeMessages = claudeMessages.filter { now.timeIntervalSince($0.value.at) < Self.messageMemory }
        return drained
    }

    // MARK: - Incremental reads

    /// Tokens appended to a provider's transcripts since the previous call.
    private func drain(_ kind: ProviderKind, now: Date) -> Int {
        guard let directory = directories[kind] else { return 0 }
        var cursorsForKind = cursors[kind, default: [:]]
        var tokens = 0
        for (url, size) in activeFiles(in: directory, now: now) {
            var cursor: Cursor
            if let known = cursorsForKind[url] {
                cursor = known
            } else {
                // A session already in flight needs its running total recovered, or its
                // next event would have nothing to subtract from and the first burst of
                // work after launch would go unseen.
                cursor = Cursor(offset: size)
                if kind == .codex { cursor.cumulative = codexBaseline(url, size: size) }
            }
            cursor.lastSeen = now
            // A rotated or truncated file restarts from its beginning.
            if size < cursor.offset {
                cursor.offset = 0
                cursor.cumulative = nil
            }
            if size > cursor.offset, let (chunk, consumed) = readAppended(url, from: cursor.offset) {
                cursor.offset += consumed
                switch kind {
                case .claude: tokens += claudeTokens(in: chunk, now: now)
                case .codex: tokens += codexTokens(in: chunk, cumulative: &cursor.cumulative)
                }
            }
            cursorsForKind[url] = cursor
        }
        cursors[kind] = cursorsForKind.filter { now.timeIntervalSince($0.value.lastSeen) < Self.activeFileWindow }
        return tokens
    }

    /// Transcripts touched recently, with their current size.
    private func activeFiles(in directory: URL, now: Date) -> [(URL, UInt64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, UInt64)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) < Self.activeFileWindow,
                  let size = values.fileSize else { continue }
            files.append((url, UInt64(size)))
        }
        return files
    }

    /// Bytes added since `offset`, trimmed to the last complete line so a half-written
    /// record is left for the next sample.
    private func readAppended(_ url: URL, from offset: UInt64) -> (Data, UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        guard let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        let end = data.index(after: lastBreak)
        return (data[data.startIndex..<end], UInt64(end - data.startIndex))
    }

    // MARK: - Per-provider accounting

    private func claudeTokens(in chunk: Data, now: Date) -> Int {
        var tokens = 0
        for line in chunk.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: Data("\"usage\"".utf8)) != nil,
                  let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  JSON.string(entry["type"]) == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let effective = Int(JSON.double(usage["input_tokens"]) ?? 0)
                + Int(JSON.double(usage["output_tokens"]) ?? 0)
                + Int(JSON.double(usage["cache_creation_input_tokens"]) ?? 0)
            let id = JSON.string(message["id"]) ?? JSON.string(entry["requestId"]) ?? JSON.string(entry["uuid"]) ?? ""
            let counted = claudeMessages[id]?.value ?? 0
            if effective > counted {
                tokens += effective - counted
                claudeMessages[id] = (effective, now)
            }
        }
        return tokens
    }

    /// The newest running total already recorded in a session file, read from its tail.
    private func codexBaseline(_ url: URL, size: UInt64) -> Int? {
        let span = UInt64(Self.baselineScan)
        let offset = size > span ? size - span : 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              var data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // A tail read starts mid-line unless it started at the very beginning.
        if offset > 0, let firstBreak = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.index(after: firstBreak)...]
        }
        var cumulative: Int?
        _ = codexTokens(in: data, cumulative: &cumulative)
        return cumulative
    }

    private func codexTokens(in chunk: Data, cumulative: inout Int?) -> Int {
        var latest: Int?
        for line in chunk.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: Data("\"token_count\"".utf8)) != nil,
                  let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let info = payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any],
                  let total = JSON.double(totals["total_tokens"]) else { continue }
            // `cached_input_tokens` is a subset of `input_tokens` inside the same total.
            let cached = JSON.double(totals["cached_input_tokens"]) ?? 0
            latest = max(latest ?? 0, Int(total - cached))
        }
        guard let latest else { return 0 }
        defer { cumulative = latest }
        guard let previous = cumulative else { return 0 }
        return max(0, latest - previous)
    }
}

/// Trailing-window throughput. Token deltas are dropped in as they are observed and
/// read back as tokens per minute; while the window is still filling, the total is
/// scaled up to a full minute so a busy start is not reported as idle.
struct RateWindow: Sendable {
    /// Span the rate is averaged over.
    static let span: TimeInterval = 60
    /// Observation time a rate needs before it is divided out.
    static let minimumElapsed: TimeInterval = 15

    private var samples: [(at: Date, tokens: Int)] = []
    private let startedAt: Date

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    mutating func add(_ tokens: Int, at now: Date) {
        samples.removeAll { now.timeIntervalSince($0.at) >= Self.span }
        guard tokens > 0 else { return }
        samples.append((now, tokens))
    }

    func tokensPerMinute(at now: Date) -> Int {
        let total = samples.reduce(0) { $0 + $1.tokens }
        guard total > 0 else { return 0 }
        let elapsed = max(Self.minimumElapsed, min(Self.span, now.timeIntervalSince(startedAt)))
        return Int(Double(total) * Self.span / elapsed)
    }
}

/// Publishes each provider's current cadence for the menu bar to animate.
@MainActor
final class UsageRateMonitor: ObservableObject {
    /// How often the transcripts are polled.
    static let sampleInterval: TimeInterval = 5

    @Published private(set) var cadences: [ProviderKind: PedalCadence] = [:]
    @Published private(set) var rates: [ProviderKind: Int] = [:]

    private let sampler: TranscriptRateSampler
    /// Preview builds run on fixtures and never read this Mac's transcripts.
    private let isLive: Bool
    private var thresholds: CadenceThresholds
    private var windows: [ProviderKind: RateWindow] = [:]
    private var pollTask: Task<Void, Never>?

    init(sampler: TranscriptRateSampler = TranscriptRateSampler(), thresholds: CadenceThresholds = .default,
         isLive: Bool = true) {
        self.sampler = sampler
        self.thresholds = thresholds
        self.isLive = isLive
        cadences = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, .idle) })
        windows = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, RateWindow()) })
    }

    deinit { pollTask?.cancel() }

    func apply(thresholds: CadenceThresholds) {
        guard thresholds != self.thresholds else { return }
        self.thresholds = thresholds
        cadences = rates.mapValues { thresholds.cadence(forTokensPerMinute: $0) }
    }

    /// Starts or stops sampling to match the preference; repeat calls with the same
    /// value leave the running sampler alone.
    func setEnabled(_ enabled: Bool) {
        guard isLive else { return }
        if enabled { start() } else { stop() }
    }

    func start() {
        guard isLive, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let drained = await self.sampler.drainTokens()
                self.absorb(drained, at: Date())
                try? await Task.sleep(nanoseconds: UInt64(Self.sampleInterval * 1_000_000_000))
            }
        }
    }

    /// Folds a round of token deltas into the windows and republishes the cadences.
    func absorb(_ drained: [ProviderKind: Int], at now: Date) {
        var measured: [ProviderKind: Int] = [:]
        for kind in ProviderKind.allCases {
            var window = windows[kind] ?? RateWindow()
            window.add(drained[kind] ?? 0, at: now)
            windows[kind] = window
            measured[kind] = window.tokensPerMinute(at: now)
        }
        rates = measured
        cadences = measured.mapValues { thresholds.cadence(forTokensPerMinute: $0) }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        guard cadences.values.contains(where: { $0 != .idle }) else { return }
        windows = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, RateWindow()) })
        rates = [:]
        cadences = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, .idle) })
    }
}
