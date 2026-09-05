import Foundation

enum ProviderKind: String, CaseIterable, Sendable {
    case claude
    case codex

    /// One-letter tag shown in the menu bar.
    var shortLabel: String {
        switch self {
        case .claude: return "C"
        case .codex: return "X"
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// The single window shown in the menu bar: Claude always its session; Codex its
    /// session, or the weekly window when the API reports no session window.
    func menuBarWindow(in snapshot: UsageSnapshot) -> UsageWindow? {
        switch self {
        case .claude: return snapshot.session
        case .codex: return snapshot.session ?? snapshot.weekly
        }
    }
}

struct UsageWindow: Sendable {
    let usedPercent: Double
    let resetsAt: Date?
}

struct LabeledWindow: Sendable {
    let label: String
    let window: UsageWindow
}

/// Banked "full reset" credits Codex hands out; each one wipes the current rate-limit windows.
struct ResetCredits: Sendable {
    let availableCount: Int
    let earliestExpiry: Date?
}

struct UsageSnapshot: Sendable {
    /// Rolling ~5 hour window.
    let session: UsageWindow?
    /// Rolling ~7 day window.
    let weekly: UsageWindow?
    /// Extra windows worth listing in the menu (e.g. Claude's per-model weekly caps).
    let extras: [LabeledWindow]
    let planLabel: String?
    /// Signed-in account, shown at the right of the provider header.
    let accountLabel: String?
    let resetCredits: ResetCredits?
    /// Tokens consumed today according to this Mac's local transcripts.
    let tokensToday: Int?
    let fetchedAt: Date
    /// Shown in the menu when the numbers did not come straight from the live API.
    let sourceNote: String?

    init(session: UsageWindow?, weekly: UsageWindow?, extras: [LabeledWindow] = [], planLabel: String?,
         accountLabel: String? = nil, resetCredits: ResetCredits? = nil, tokensToday: Int? = nil,
         fetchedAt: Date, sourceNote: String?) {
        self.session = session
        self.weekly = weekly
        self.extras = extras
        self.planLabel = planLabel
        self.accountLabel = accountLabel
        self.resetCredits = resetCredits
        self.tokensToday = tokensToday
        self.fetchedAt = fetchedAt
        self.sourceNote = sourceNote
    }
}

struct ProviderStatus: Sendable {
    var snapshot: UsageSnapshot?
    var errorMessage: String?
    var isLoading = false
}

enum ProviderError: LocalizedError {
    case notLoggedIn(String)
    case tokenExpired(String)
    case rateLimited
    case http(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let hint): return "Not logged in. \(hint)"
        case .tokenExpired(let hint): return "Token expired. \(hint)"
        case .rateLimited: return "Usage API rate-limited this app; backing off."
        case .http(let status, let body): return "HTTP \(status): \(body)"
        case .decoding(let detail): return "Unexpected response: \(detail)"
        }
    }
}

protocol UsageProvider: Sendable {
    var kind: ProviderKind { get }
    func fetch() async throws -> UsageSnapshot
}

/// Whether percentages are shown as consumed quota or what is still available.
enum DisplayMode: String, Sendable {
    case used
    case remaining

    private static let defaultsKey = "displayMode"

    static func load() -> DisplayMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(DisplayMode.init(rawValue:)) ?? .used
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    func value(usedPercent: Double) -> Double {
        self == .used ? usedPercent : max(0, 100 - usedPercent)
    }
}
