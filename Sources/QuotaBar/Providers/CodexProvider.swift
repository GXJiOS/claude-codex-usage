import Foundation

/// Reads the Codex CLI ChatGPT login from ~/.codex/auth.json and asks the ChatGPT
/// backend for the current rate-limit windows. Falls back to the newest
/// `rate_limits` event the CLI wrote to its session logs when the API call fails.
struct CodexProvider: UsageProvider {
    let kind: ProviderKind = .codex

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private static let userAgent = "QuotaBar/0.1 (macOS)"

    static var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private struct Credentials {
        let accessToken: String
        let accountID: String?
    }

    func fetch() async throws -> UsageSnapshot {
        let apiError: Error
        do {
            return try await fetchFromAPI()
        } catch {
            apiError = error
        }
        if let logged = SessionLogReader.latestRateLimits(codexHome: Self.codexHome) {
            let note = "session log \(Format.time(logged.recordedAt)); API: \(apiError.localizedDescription)"
            return logged.snapshot(tokensToday: Self.tokensToday, sourceNote: note)
        }
        throw apiError
    }

    private static var tokensToday: Int {
        TokenLog.codexTokensToday(sessionsDir: codexHome.appendingPathComponent("sessions", isDirectory: true))
    }

    // MARK: - Live API

    /// Raw JSON of the ChatGPT backend endpoints, for `--once --raw` inspection.
    func fetchRawJSON() async throws -> String {
        let credentials = try loadCredentials()
        var out: [String] = []
        for path in ["wham/usage", "wham/rate-limit-reset-credits"] {
            let url = URL(string: "https://chatgpt.com/backend-api/\(path)")!
            let response = try await HTTP.get(url, headers: headers(for: credentials))
            let body: String
            if let object = try? JSONSerialization.jsonObject(with: response.data),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                body = String(decoding: pretty, as: UTF8.self)
            } else {
                body = response.bodyPreview
            }
            out.append("GET \(path) → HTTP \(response.status)\n\(body)")
        }
        return out.joined(separator: "\n\n")
    }

    private func headers(for credentials: Credentials) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
            "User-Agent": Self.userAgent,
        ]
        if let accountID = credentials.accountID {
            headers["chatgpt-account-id"] = accountID
        }
        return headers
    }

    private func fetchFromAPI() async throws -> UsageSnapshot {
        let credentials = try loadCredentials()
        let response = try await HTTP.get(Self.usageURL, headers: headers(for: credentials))
        switch response.status {
        case 200:
            break
        case 401, 403:
            throw ProviderError.tokenExpired("Run `codex` once so it refreshes the login.")
        case 429:
            throw ProviderError.rateLimited
        default:
            throw ProviderError.http(status: response.status, body: response.bodyPreview)
        }

        let root = try JSON.object(from: response.data)
        let rateLimit = (root["rate_limit"] ?? root["rate_limits"]) as? [String: Any] ?? root
        let windows = RateWindows(
            primary: RawWindow(rateLimit["primary_window"] ?? rateLimit["primary"]),
            secondary: RawWindow(rateLimit["secondary_window"] ?? rateLimit["secondary"])
        )
        guard windows.primary != nil || windows.secondary != nil else {
            throw ProviderError.decoding("no rate-limit windows in keys \(root.keys.sorted())")
        }

        let creditsSummary = root["rate_limit_reset_credits"] as? [String: Any]
        let availableCount = Int(JSON.double(creditsSummary?["available_count"]) ?? 0)
        let resetCredits = await resetCredits(count: availableCount, credentials: credentials)

        return windows.snapshot(
            plan: JSON.string(root["plan_type"]),
            accountLabel: JSON.string(root["email"]),
            resetCredits: resetCredits,
            tokensToday: Self.tokensToday,
            fetchedAt: Date(),
            sourceNote: nil
        )
    }

    /// Earliest expiry among still-available credits; the count alone when the detail call fails.
    private func resetCredits(count: Int, credentials: Credentials) async -> ResetCredits {
        guard count > 0,
              let response = try? await HTTP.get(Self.resetCreditsURL, headers: headers(for: credentials)),
              response.status == 200,
              let root = try? JSON.object(from: response.data),
              let credits = root["credits"] as? [[String: Any]] else {
            return ResetCredits(availableCount: count, earliestExpiry: nil)
        }
        let expiries = credits
            .filter { JSON.string($0["status"]) == "available" }
            .compactMap { JSON.date($0["expires_at"]) }
        return ResetCredits(availableCount: count, earliestExpiry: expiries.min())
    }

    private func loadCredentials() throws -> Credentials {
        let authURL = Self.codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL) else {
            throw ProviderError.notLoggedIn("No \(authURL.path); run `codex login`.")
        }
        let root = try JSON.object(from: data)
        guard let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            throw ProviderError.notLoggedIn("auth.json has no ChatGPT tokens; run `codex login`.")
        }
        if let expiry = Self.jwtExpiry(accessToken), expiry < Date() {
            throw ProviderError.tokenExpired("Run `codex` once so it refreshes the login.")
        }
        return Credentials(accessToken: accessToken, accountID: tokens["account_id"] as? String)
    }

    /// Reads the `exp` claim of a JWT without verifying it; only used to skip doomed requests.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return JSON.date(claims["exp"])
    }
}

/// One rate-limit window as either the API or the session log describes it.
struct RawWindow {
    let usedPercent: Double
    let windowSeconds: Double?
    let resetsAt: Date?

    init?(_ value: Any?) {
        guard let object = value as? [String: Any],
              let used = JSON.double(object["used_percent"]) else { return nil }
        usedPercent = used
        if let seconds = JSON.double(object["limit_window_seconds"]) {
            windowSeconds = seconds
        } else if let minutes = JSON.double(object["window_minutes"]) {
            windowSeconds = minutes * 60
        } else {
            windowSeconds = nil
        }
        if let date = JSON.date(object["reset_at"] ?? object["resets_at"]) {
            resetsAt = date
        } else if let after = JSON.double(object["reset_after_seconds"] ?? object["resets_in_seconds"]) {
            resetsAt = Date(timeIntervalSinceNow: after)
        } else {
            resetsAt = nil
        }
    }

    var usageWindow: UsageWindow {
        UsageWindow(usedPercent: usedPercent, resetsAt: resetsAt)
    }
}

/// Codex labels its windows primary/secondary; which one is the 5-hour session and
/// which is the week depends on the plan, so classify by window length.
struct RateWindows {
    let primary: RawWindow?
    let secondary: RawWindow?

    private static let sessionMaxSeconds: Double = 6 * 3600

    func snapshot(plan: String?, accountLabel: String? = nil, resetCredits: ResetCredits? = nil,
                  tokensToday: Int? = nil, fetchedAt: Date, sourceNote: String?) -> UsageSnapshot {
        let all = [primary, secondary].compactMap { $0 }
        var session: RawWindow?
        var weekly: RawWindow?
        for window in all {
            if let seconds = window.windowSeconds, seconds > Self.sessionMaxSeconds {
                weekly = weekly ?? window
            } else {
                session = session ?? window
            }
        }
        return UsageSnapshot(
            session: session?.usageWindow,
            weekly: weekly?.usageWindow,
            planLabel: plan?.capitalized,
            accountLabel: accountLabel,
            resetCredits: resetCredits,
            tokensToday: tokensToday,
            fetchedAt: fetchedAt,
            sourceNote: sourceNote
        )
    }
}

/// Finds the newest `token_count` event with `rate_limits` in ~/.codex/sessions/**/*.jsonl.
enum SessionLogReader {
    struct Logged {
        let windows: RateWindows
        let plan: String?
        let recordedAt: Date

        func snapshot(tokensToday: Int?, sourceNote: String) -> UsageSnapshot {
            windows.snapshot(plan: plan, tokensToday: tokensToday, fetchedAt: recordedAt, sourceNote: sourceNote)
        }
    }

    private static let tailBytes = 256 * 1024
    private static let filesToScan = 5

    static func latestRateLimits(codexHome: URL) -> Logged? {
        let sessionsDir = codexHome.appendingPathComponent("sessions", isDirectory: true)
        for file in newestLogFiles(in: sessionsDir) {
            if let logged = lastRateLimits(in: file) { return logged }
        }
        return nil
    }

    private static func newestLogFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var dated: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            dated.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(filesToScan).map { $0.0 }
    }

    private static func lastRateLimits(in file: URL) -> Logged? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines.reversed() {
            guard line.range(of: Data("\"rate_limits\"".utf8)) != nil,
                  let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let windows = RateWindows(primary: RawWindow(limits["primary"]), secondary: RawWindow(limits["secondary"]))
            guard windows.primary != nil || windows.secondary != nil else { continue }
            let recordedAt = JSON.date(event["timestamp"]) ?? Date()
            return Logged(windows: windows, plan: JSON.string(limits["plan_type"]), recordedAt: recordedAt)
        }
        return nil
    }
}
