import Foundation
import CryptoKit
import os

/// Reads Claude Code's OAuth token from the login Keychain and asks Anthropic's
/// OAuth usage endpoint for the 5-hour and 7-day windows.
final class ClaudeProvider: UsageProvider, @unchecked Sendable {
    let kind: ProviderKind = .claude

    private struct AccountCache {
        let credentialID: SHA256.Digest
        let email: String
    }

    /// Reuses the profile while the credential fingerprint matches the current login.
    private let cachedEmail = OSAllocatedUnfairLock<AccountCache?>(initialState: nil)

    private let readCredentials: @Sendable () throws -> Data
    private let get: @Sendable (URL, [String: String]) async throws -> HTTP.Response
    private let tokensToday: @Sendable () -> Int?

    init(readCredentials: @escaping @Sendable () throws -> Data = {
        try Keychain.genericPassword(service: "Claude Code-credentials")
    }, get: @escaping @Sendable (URL, [String: String]) async throws -> HTTP.Response = {
        try await HTTP.get($0, headers: $1)
    }, tokensToday: @escaping @Sendable () -> Int? = {
        TokenLog.claudeTokensToday(projectsDir: ClaudeProvider.projectsDir)
    }) {
        self.readCredentials = readCredentials
        self.get = get
        self.tokensToday = tokensToday
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Same UA family as the CLI so the request lands in the CLI's rate-limit bucket.
    private static let userAgent = "claude-code/2.1.261"

    private struct Credentials {
        let accessToken: String
        let plan: String?
    }

    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// Claude Code's transcript root (CLAUDE_CONFIG_DIR is honoured when set).
    private static var projectsDir: URL {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        return home.appendingPathComponent("projects", isDirectory: true)
    }

    /// Raw usage + profile JSON, for `--once --raw` inspection of the undocumented response shapes.
    func fetchRawJSON() async throws -> String {
        let credentials = try loadCredentials()
        var out: [String] = []
        for (name, url) in [("usage", Self.usageURL), ("profile", Self.profileURL)] {
            let response = try await request(url, with: credentials)
            let body: String
            if let object = try? JSONSerialization.jsonObject(with: response.data),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                body = String(decoding: pretty, as: UTF8.self)
            } else {
                body = response.bodyPreview
            }
            out.append("GET \(name) → HTTP \(response.status)\n\(body)")
        }
        return out.joined(separator: "\n\n")
    }

    private func requestUsage(with credentials: Credentials) async throws -> HTTP.Response {
        try await request(Self.usageURL, with: credentials)
    }

    private func request(_ url: URL, with credentials: Credentials) async throws -> HTTP.Response {
        try await get(url, [
            "Authorization": "Bearer \(credentials.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": Self.userAgent,
        ])
    }

    func fetch() async throws -> UsageSnapshot {
        let credentials = try loadCredentials()
        let response = try await requestUsage(with: credentials)
        switch response.status {
        case 200:
            break
        case 401, 403:
            throw ProviderError.tokenExpired("Run `claude` once so it refreshes the login.")
        case 429:
            throw ProviderError.rateLimited
        default:
            throw ProviderError.http(status: response.status, body: response.bodyPreview)
        }

        let root = try JSON.object(from: response.data)
        func window(_ key: String) -> UsageWindow? {
            guard let object = root[key] as? [String: Any],
                  let used = JSON.double(object["utilization"]) else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: JSON.date(object["resets_at"]))
        }

        let session = window("five_hour")
        let weekly = window("seven_day")
        guard session != nil || weekly != nil else {
            throw ProviderError.decoding("no five_hour/seven_day in keys \(root.keys.sorted())")
        }

        // Per-model weekly caps (Fable, Opus, …) arrive as `limits[]` entries of kind
        // weekly_scoped with the model name under scope.model.display_name.
        var extras: [LabeledWindow] = []
        for limit in root["limits"] as? [[String: Any]] ?? [] {
            guard JSON.string(limit["kind"]) == "weekly_scoped",
                  let percent = JSON.double(limit["percent"]) else { continue }
            let scope = limit["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any]).flatMap { JSON.string($0["display_name"]) }
            let label = model ?? "Scoped"
            guard !extras.contains(where: { $0.label == label }) else { continue }
            extras.append(LabeledWindow(label: label, window: UsageWindow(usedPercent: percent, resetsAt: JSON.date(limit["resets_at"]))))
        }
        if extras.isEmpty {
            if let opus = window("seven_day_opus") { extras.append(LabeledWindow(label: "Opus", window: opus)) }
            if let sonnet = window("seven_day_sonnet") { extras.append(LabeledWindow(label: "Sonnet", window: sonnet)) }
        }

        return UsageSnapshot(
            session: session,
            weekly: weekly,
            extras: extras,
            planLabel: credentials.plan,
            accountLabel: await accountEmail(with: credentials),
            tokensToday: tokensToday(),
            fetchedAt: Date(),
            sourceNote: nil
        )
    }

    /// `account.email` from the OAuth profile endpoint; nil (and retried next refresh) on any failure.
    private func accountEmail(with credentials: Credentials) async -> String? {
        let credentialID = SHA256.hash(data: Data(credentials.accessToken.utf8))
        if let email = cachedEmail.withLock({ cache in
            cache?.credentialID == credentialID ? cache?.email : nil
        }) { return email }

        guard let response = try? await request(Self.profileURL, with: credentials), response.status == 200,
              let root = try? JSON.object(from: response.data),
              let account = root["account"] as? [String: Any],
              let email = JSON.string(account["email"]), !email.isEmpty else { return nil }
        cachedEmail.withLock { $0 = AccountCache(credentialID: credentialID, email: email) }
        return email
    }

    private func loadCredentials() throws -> Credentials {
        let data: Data
        do {
            data = try readCredentials()
        } catch let error as KeychainError where error.status == errSecItemNotFound {
            throw ProviderError.notLoggedIn("Run `claude` and log in once.")
        }

        guard let root = try? JSON.object(from: data),
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ProviderError.notLoggedIn("Keychain item has no claudeAiOauth entry; run `claude` and log in.")
        }
        if let expiresAt = JSON.date(oauth["expiresAt"]), expiresAt < Date() {
            throw ProviderError.tokenExpired("Run `claude` once so it refreshes the login.")
        }
        let plan = JSON.string(oauth["subscriptionType"])?.capitalized
        return Credentials(accessToken: token, plan: plan)
    }
}
