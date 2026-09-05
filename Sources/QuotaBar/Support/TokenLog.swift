import Foundation

/// Sums today's token consumption from the transcripts the CLIs write on this Mac.
/// Neither usage API reports token counts, so this is machine-local by nature.
enum TokenLog {
    /// Claude Code: every assistant entry in ~/.claude/projects/**/*.jsonl carries
    /// `message.usage`. Streaming writes one line per content block of the same message,
    /// with the usage growing as output completes, so the largest total per message id
    /// is kept and summed: input + output + cache creation + cache read.
    static func claudeTokensToday(projectsDir: URL) -> Int {
        let dayStart = Calendar.current.startOfDay(for: Date())
        var perMessage: [String: Int] = [:]
        for file in jsonlFiles(in: projectsDir, modifiedAfter: dayStart) {
            for line in lines(of: file, containing: "\"usage\"") {
                guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      JSON.string(entry["type"]) == "assistant",
                      let timestamp = JSON.date(entry["timestamp"]), timestamp >= dayStart,
                      let message = entry["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                let id = JSON.string(message["id"]) ?? JSON.string(entry["requestId"]) ?? JSON.string(entry["uuid"]) ?? ""
                let total = Int(JSON.double(usage["input_tokens"]) ?? 0)
                    + Int(JSON.double(usage["output_tokens"]) ?? 0)
                    + Int(JSON.double(usage["cache_creation_input_tokens"]) ?? 0)
                    + Int(JSON.double(usage["cache_read_input_tokens"]) ?? 0)
                perMessage[id] = max(perMessage[id] ?? 0, total)
            }
        }
        return perMessage.values.reduce(0, +)
    }

    /// Codex: `token_count` events carry `info.total_token_usage`, cumulative per session.
    /// Today's share of a session is its highest cumulative total seen today minus the
    /// highest seen before today, which also survives duplicated events.
    static func codexTokensToday(sessionsDir: URL) -> Int {
        let dayStart = Calendar.current.startOfDay(for: Date())
        var total = 0
        for file in jsonlFiles(in: sessionsDir, modifiedAfter: dayStart) {
            var beforeToday = 0
            var today = 0
            for line in lines(of: file, containing: "\"token_count\"") {
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = event["payload"] as? [String: Any],
                      let info = payload["info"] as? [String: Any],
                      let cumulative = info["total_token_usage"] as? [String: Any],
                      let count = JSON.double(cumulative["total_tokens"]),
                      let timestamp = JSON.date(event["timestamp"]) else { continue }
                if timestamp >= dayStart {
                    today = max(today, Int(count))
                } else {
                    beforeToday = max(beforeToday, Int(count))
                }
            }
            total += max(0, today - beforeToday)
        }
        return total
    }

    // MARK: - File helpers

    private static func jsonlFiles(in directory: URL, modifiedAfter cutoff: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= cutoff else { continue }
            files.append(url)
        }
        return files
    }

    private static func lines(of file: URL, containing marker: String) -> [Data] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
        let needle = Data(marker.utf8)
        return data.split(separator: UInt8(ascii: "\n")).filter { $0.range(of: needle) != nil }
    }
}
