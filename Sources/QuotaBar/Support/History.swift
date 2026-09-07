import Foundation

/// One sample of a provider's numbers, written as a single JSONL line.
struct HistoryRecord: Codable, Sendable {
    let at: Date
    let provider: String
    /// Used percentage of the rolling session window.
    let session: Double?
    /// Used percentage of the rolling weekly window.
    let weekly: Double?
    /// Tokens consumed today according to this Mac's transcripts.
    let tokensToday: Int?

    var kind: ProviderKind? { ProviderKind(rawValue: provider) }
}

/// Append-only JSONL log at ~/Library/Application Support/QuotaBar/history.jsonl.
/// Plain text on purpose: the file stays readable with `tail` and survives a schema change,
/// since an unparsable line is skipped rather than invalidating the whole store.
enum History {
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QuotaBar", isDirectory: true)
                   .appendingPathComponent("history.jsonl")
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func append(_ records: [HistoryRecord]) {
        guard !records.isEmpty else { return }
        var blob = Data()
        for record in records {
            guard let line = try? encoder.encode(record) else { continue }
            blob.append(line)
            blob.append(0x0A)
        }
        guard !blob.isEmpty else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            try? blob.write(to: fileURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: blob)
    }

    /// Records newer than `days` ago, oldest first. Unparsable lines are skipped.
    static func load(days: Int) -> [HistoryRecord] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let cutoff = Date(timeIntervalSinceNow: -Double(days) * 86_400)
        var records: [HistoryRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(HistoryRecord.self, from: data),
                  record.at >= cutoff else { continue }
            records.append(record)
        }
        return records.sorted { $0.at < $1.at }
    }

    /// Rewrites the file without records older than the retention window. Launch-time only.
    static func prune(retentionDays: Int) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let kept = load(days: retentionDays)
        var blob = Data()
        for record in kept {
            guard let line = try? encoder.encode(record) else { continue }
            blob.append(line)
            blob.append(0x0A)
        }
        try? blob.write(to: fileURL)
    }
}

/// Decides when a refresh is worth recording. Polling runs every few minutes, so samples
/// are thinned to one per provider per quarter hour to keep the file small enough to
/// parse in one go.
@MainActor
final class HistoryRecorder {
    static let minimumSpacing: TimeInterval = 15 * 60

    private var lastWrite: [ProviderKind: Date] = [:]

    func record(_ statuses: [ProviderKind: ProviderStatus], now: Date = Date()) {
        var due: [HistoryRecord] = []
        for (kind, status) in statuses {
            guard let snapshot = status.snapshot else { continue }
            if let last = lastWrite[kind], now.timeIntervalSince(last) < Self.minimumSpacing { continue }
            lastWrite[kind] = now
            due.append(HistoryRecord(
                at: snapshot.fetchedAt,
                provider: kind.rawValue,
                session: snapshot.session?.usedPercent,
                weekly: snapshot.weekly?.usedPercent,
                tokensToday: snapshot.tokensToday
            ))
        }
        History.append(due)
    }
}
