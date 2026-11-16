import Foundation

/// Reads Gemini quotas through the Antigravity CLI's read-only `agy -p "/usage"` command.
/// That command answers without starting an agent turn or spending quota, and the CLI
/// keeps its own Google sign-in fresh, so this app never touches the credential.
final class GeminiProvider: UsageProvider {
    let kind: ProviderKind = .gemini

    private let runUsage: @Sendable () throws -> Data

    init(runUsage: @escaping @Sendable () throws -> Data = { try GeminiProvider.runCLI() }) {
        self.runUsage = runUsage
    }

    static let signInHint = "Run `agy` in Terminal and sign in."

    /// A login item or Finder launch has no shell PATH, so the CLI is located by path.
    static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [home.appendingPathComponent(".local/bin/agy"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
                          URL(fileURLWithPath: "/usr/local/bin/agy")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// One `/usage` call takes several seconds; `--log-file /dev/null` keeps polling from
    /// leaving a CLI log file behind on every refresh.
    static func runCLI(executable: URL? = executable()) throws -> Data {
        guard let executable else {
            throw ProviderError.notLoggedIn("Install the Antigravity CLI, then run `agy` and sign in.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--output-format", "json", "--log-file", "/dev/null"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let result = try Keychain.run(process, timeout: 45)
        return try checkedOutput(exitCode: result.exitCode, data: result.data)
    }

    /// Only a clean exit counts as an answer; a failed run reports its exit code with the
    /// CLI's own message when the output carries one.
    static func checkedOutput(exitCode: Int32, data: Data) throws -> Data {
        guard exitCode != 0 || data.isEmpty else { return data }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { JSON.string($0["response"]) } ?? String(decoding: data, as: UTF8.self)
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
        throw ProviderError.decoding(detail.isEmpty ? "agy exited with code \(exitCode) and no output"
                                                    : "agy exited with code \(exitCode): \(detail)")
    }

    /// The CLI's JSON reply, pretty-printed, for `--once --raw` and the diagnostics page.
    func fetchRawJSON() async throws -> String {
        let data = try await usageData()
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return String(decoding: data, as: UTF8.self)
        }
        return "agy -p /usage\n" + String(decoding: pretty, as: UTF8.self)
    }

    func fetch() async throws -> UsageSnapshot {
        try Self.snapshot(from: try await usageData(), now: Date())
    }

    /// Runs the blocking CLI call off the cooperative thread pool.
    private func usageData() async throws -> Data {
        let runUsage = runUsage
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try runUsage() })
            }
        }
    }

    /// Maps `command.data.groups[].buckets[]`: `gemini-5h` is the session window,
    /// `gemini-weekly` the weekly window, and the Argon bucket its own per-model row.
    /// The "Claude and GPT models" group belongs to other providers and stays out.
    static func snapshot(from data: Data, now: Date) throws -> UsageSnapshot {
        let root = try JSON.object(from: data)
        let status = JSON.string(root["status"]) ?? "?"
        guard status == "SUCCESS" else {
            let response = (JSON.string(root["response"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.decoding("agy /usage \(status): \(response.prefix(160))")
        }
        let groups = ((root["command"] as? [String: Any])?["data"] as? [String: Any])?["groups"] as? [[String: Any]] ?? []

        var session: UsageWindow?
        var weekly: UsageWindow?
        var extras: [LabeledWindow] = []
        var seenIDs: [String] = []
        for group in groups {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = JSON.string(bucket["id"]) else { continue }
                seenIDs.append(id)
                if (bucket["disabled"] as? Bool) == true { continue }
                // `remaining_fraction` is omitted when it is zero: no field means the bucket is spent.
                let remaining = min(1, max(0, JSON.double(bucket["remaining_fraction"]) ?? 0))
                let window = UsageWindow(usedPercent: (1 - remaining) * 100, resetsAt: JSON.date(bucket["reset_time"]))
                if id == "gemini-5h" {
                    session = window
                } else if id == "gemini-weekly" {
                    weekly = window
                } else if id.contains("argon"), !extras.contains(where: { $0.label == "Argon" }) {
                    extras.append(LabeledWindow(label: "Argon", window: window))
                }
            }
        }
        guard session != nil || weekly != nil else {
            throw ProviderError.decoding("no gemini-5h/gemini-weekly bucket in \(seenIDs)")
        }
        return UsageSnapshot(session: session, weekly: weekly, extras: extras, planLabel: nil,
                             fetchedAt: now, sourceNote: nil)
    }
}
