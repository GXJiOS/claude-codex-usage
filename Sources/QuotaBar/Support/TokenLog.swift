import Foundation
import SQLite3

/// Sums today's token consumption from the transcripts the CLIs write on this Mac.
/// None of the usage APIs report token counts, so this is machine-local by nature.
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

    /// Antigravity (agy): every model call is a `gen_metadata` row in its conversation's
    /// database, dated by the step it belongs to. Summed: input + output + thinking + cache read.
    static func geminiTokensToday(conversationsDir: URL) -> Int {
        let dayStart = Calendar.current.startOfDay(for: Date())
        var total = 0
        for database in AgyStore.databases(in: conversationsDir, modifiedAfter: dayStart) {
            guard let calls = AgyStore.datedGenerations(in: database) else { continue }
            for call in calls where (call.at ?? .distantPast) >= dayStart {
                total += call.generation.total
            }
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

// MARK: - Antigravity conversation stores

/// One model call agy recorded in a conversation database.
struct AgyGeneration: Equatable, Sendable {
    let input: Int
    let output: Int
    let thinking: Int
    let cacheRead: Int
    /// The conversation step the call belongs to; the step carries the timestamp.
    let stepIndex: Int?

    /// Work done by the call, the measure the rate sampler uses: cache reads stay out.
    var effective: Int { input + output + thinking }
    var total: Int { effective + cacheRead }
}

/// Reads agy's per-conversation SQLite stores under ~/.gemini/antigravity-cli/conversations.
///
/// The records are undocumented protobuf. A `gen_metadata` row's field 1.4 holds the call's
/// usage (2 input without cache, 3 output, 5 cache read, 9 thinking), and field 1.20 holds
/// string pairs that include `last_step_index`. A `steps` row's metadata starts with the step's
/// creation time in field 1.1. These numbers match the `usage` that `agy -p --output-format json`
/// prints, which sums a conversation's rows. A row that does not decode counts as nothing.
enum AgyStore {
    static var conversationsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
    }

    /// Conversation databases written since `cutoff`. A live session writes to the `-wal`
    /// file first, so that file's time counts too.
    static func databases(in directory: URL, modifiedAfter cutoff: Date) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { url in
            guard url.pathExtension == "db",
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return false }
            let wal = URL(fileURLWithPath: url.path + "-wal")
            let walModified = (try? wal.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let modified = [values.contentModificationDate, walModified].compactMap { $0 }.max()
            return (modified ?? .distantPast) >= cutoff
        }
    }

    /// Calls with a row index of at least `fromIndex`, in index order; with no `fromIndex`,
    /// only the newest call. Nil when the database cannot be read.
    static func generations(in database: URL, fromIndex: Int?) -> [(index: Int, generation: AgyGeneration)]? {
        withDatabase(database) { db in
            let sql = "SELECT idx, data FROM gen_metadata WHERE idx >= coalesce(?1, (SELECT max(idx) FROM gen_metadata)) ORDER BY idx"
            let rows = rows(db, sql) { statement in
                if let fromIndex { sqlite3_bind_int64(statement, 1, Int64(fromIndex)) } else { sqlite3_bind_null(statement, 1) }
            }
            return rows?.compactMap { index, blob in
                generation(from: blob).map { (index, $0) }
            }
        }
    }

    /// Every call in the database with the creation time of its step.
    static func datedGenerations(in database: URL) -> [(generation: AgyGeneration, at: Date?)]? {
        withDatabase(database) { db in
            guard let steps = rows(db, "SELECT idx, metadata FROM steps"),
                  let calls = rows(db, "SELECT idx, data FROM gen_metadata ORDER BY idx") else { return nil }
            var times: [Int: Date] = [:]
            for (index, blob) in steps { times[index] = stepTime(from: blob) }
            return calls.compactMap { _, blob in
                generation(from: blob).map { ($0, $0.stepIndex.flatMap { times[$0] }) }
            }
        }
    }

    static func generation(from blob: ArraySlice<UInt8>) -> AgyGeneration? {
        guard let record = Protobuf.fields(blob).flatMap({ Protobuf.bytes(1, in: $0) }).flatMap(Protobuf.fields),
              let usage = Protobuf.bytes(4, in: record).flatMap(Protobuf.fields) else { return nil }
        let counts = [2, 3, 9, 5].map { Protobuf.varint($0, in: usage) ?? 0 }
        // No single call comes near 2^32 tokens; a larger value means the format changed,
        // and dropping the row keeps the sums far from overflow.
        guard counts.allSatisfy({ $0 < Self.countLimit }) else { return nil }
        let stepIndex = record.lazy.compactMap { field -> Int? in
            guard field.number == 20, case .bytes(let entry) = field.value,
                  let pair = Protobuf.fields(entry),
                  Protobuf.string(1, in: pair) == "last_step_index" else { return nil }
            return Protobuf.string(2, in: pair).flatMap { Int($0) }
        }.first
        return AgyGeneration(input: Int(counts[0]), output: Int(counts[1]), thinking: Int(counts[2]),
                             cacheRead: Int(counts[3]), stepIndex: stepIndex)
    }

    private static let countLimit: UInt64 = 1 << 32

    static func stepTime(from blob: ArraySlice<UInt8>) -> Date? {
        guard let timestamp = Protobuf.fields(blob).flatMap({ Protobuf.bytes(1, in: $0) }).flatMap(Protobuf.fields),
              let seconds = Protobuf.varint(1, in: timestamp) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: SQLite

    /// Opens the database without writing next to it. A closed conversation has no `-wal`, and
    /// a read-only open would need a `-shm` file it cannot create, so it is read as immutable.
    /// A live one is read through its WAL, falling back to the immutable read if that fails.
    private static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) -> T?) -> T? {
        let live = FileManager.default.fileExists(atPath: url.path + "-wal")
        for mode in live ? ["mode=ro", "immutable=1"] : ["immutable=1"] {
            var db: OpaquePointer?
            let opened = sqlite3_open_v2(url.absoluteString + "?" + mode, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            defer { sqlite3_close(db) }
            guard opened == SQLITE_OK, let db else { continue }
            sqlite3_busy_timeout(db, 200)
            if let result = body(db) { return result }
        }
        return nil
    }

    /// `(idx, blob)` pairs; nil when the statement fails.
    private static func rows(_ db: OpaquePointer, _ sql: String,
                             bind: (OpaquePointer) -> Void = { _ in }) -> [(Int, ArraySlice<UInt8>)]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var result: [(Int, ArraySlice<UInt8>)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let index = Int(sqlite3_column_int64(statement, 0))
                let count = Int(sqlite3_column_bytes(statement, 1))
                let bytes = sqlite3_column_blob(statement, 1).map {
                    Array(UnsafeBufferPointer(start: $0.assumingMemoryBound(to: UInt8.self), count: count))
                } ?? []
                result.append((index, bytes[...]))
            case SQLITE_DONE:
                return result
            default:
                return nil
            }
        }
    }
}

/// Enough of the protobuf wire format to walk agy's records by field number.
enum Protobuf {
    enum Value {
        case varint(UInt64)
        case bytes(ArraySlice<UInt8>)
    }

    /// The top-level fields of one message in wire order; nil when the bytes are not a message.
    static func fields(_ data: ArraySlice<UInt8>) -> [(number: Int, value: Value)]? {
        var fields: [(number: Int, value: Value)] = []
        var i = data.startIndex
        while i < data.endIndex {
            guard let key = varint(data, at: &i), key >> 3 > 0, key >> 3 <= UInt64(Int32.max) else { return nil }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint(data, at: &i) else { return nil }
                fields.append((number, .varint(value)))
            case 1:
                guard data.endIndex - i >= 8 else { return nil }
                i += 8
            case 2:
                guard let length = varint(data, at: &i), length <= UInt64(data.endIndex - i) else { return nil }
                let end = i + Int(length)
                fields.append((number, .bytes(data[i..<end])))
                i = end
            case 5:
                guard data.endIndex - i >= 4 else { return nil }
                i += 4
            default:
                return nil
            }
        }
        return fields
    }

    static func varint(_ number: Int, in fields: [(number: Int, value: Value)]) -> UInt64? {
        for field in fields where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    static func bytes(_ number: Int, in fields: [(number: Int, value: Value)]) -> ArraySlice<UInt8>? {
        for field in fields where field.number == number {
            if case .bytes(let value) = field.value { return value }
        }
        return nil
    }

    static func string(_ number: Int, in fields: [(number: Int, value: Value)]) -> String? {
        bytes(number, in: fields).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    private static func varint(_ data: ArraySlice<UInt8>, at i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < data.endIndex, shift < 64 {
            let byte = data[i]
            i += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }
}
