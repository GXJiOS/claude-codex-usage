import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusBar: StatusBarController?
    private var window: MainWindowController?
    private var notifications: UsageNotifications?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = CommandLine.arguments.contains("--preview")
        let model = SettingsModel(persistChanges: !preview)
        if preview, let theme = argument("--preview-theme").flatMap(AppTheme.init(rawValue:)) { model.settings.theme = theme }
        if preview, let language = argument("--preview-language").flatMap(AppLanguage.init(rawValue:)) { model.settings.language = language }
        model.applyTheme()
        if !preview { History.prune(retentionDays: model.settings.historyRetentionDays) }

        let store = preview
            ? UsageStore(providers: [], preview: PreviewData.statuses(state: argument("--preview-state") ?? "normal"))
            : UsageStore(providers: [ClaudeProvider(), CodexProvider()])
        self.store = store
        let notifications = UsageNotifications(enabled: !preview)
        self.notifications = notifications
        notifications.start()
        store.onFreshSnapshot = { [weak notifications] provider, snapshot in
            Task { await notifications?.process(provider: provider, snapshot: snapshot, settings: Settings.load()) }
        }
        let window = MainWindowController(store: store, model: model, notifications: notifications)
        self.window = window
        let statusBar = StatusBarController(store: store, model: model)
        statusBar.onOpenWindow = { [weak window] in window?.show() }
        self.statusBar = statusBar
        store.startPolling()
        if preview, let page = argument("--preview-page").flatMap(SettingsSection.init(rawValue:)) { model.page = page }
        if preview, let provider = argument("--preview-provider").flatMap(ProviderKind.init(rawValue:)) { model.selectedProvider = provider }
        if CommandLine.arguments.contains("--settings") { window.show() }
        if preview && CommandLine.arguments.contains("--preview-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { statusBar.showPopover() }
        }
    }

    private func argument(_ name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }
}

/// Explicit preview fixtures support visual checks with temporary preferences and isolated data.
enum PreviewData {
    static func statuses(state: String = "normal", now: Date = Date()) -> [ProviderKind: ProviderStatus] {
        if state == "empty" { return [.claude: ProviderStatus(), .codex: ProviderStatus()] }
        if state == "loading" { return [.claude: ProviderStatus(isLoading: true), .codex: ProviderStatus(isLoading: true)] }
        if state == "expired" {
            return [.claude: ProviderStatus(errorMessage: "Token expired. Run claude to refresh sign-in."),
                    .codex: ProviderStatus(errorMessage: "Token expired. Run codex to refresh sign-in.")]
        }
        let claude = UsageSnapshot(
            session: UsageWindow(usedPercent: 39, resetsAt: now.addingTimeInterval(4 * 3600)),
            weekly: UsageWindow(usedPercent: 60, resetsAt: now.addingTimeInterval(3 * 86_400)),
            extras: [LabeledWindow(label: "Opus", window: UsageWindow(usedPercent: 24, resetsAt: now.addingTimeInterval(3 * 86_400)))],
            planLabel: "Max", accountLabel: "preview@example.com", tokensToday: 1_248_000, fetchedAt: now, sourceNote: nil)
        let fallback = state == "fallback"
        let codex = UsageSnapshot(
            session: state == "weekly-only" ? nil : UsageWindow(usedPercent: 60, resetsAt: now.addingTimeInterval(2 * 3600)),
            weekly: UsageWindow(usedPercent: 82, resetsAt: now.addingTimeInterval(5 * 86_400)),
            planLabel: "Pro", accountLabel: "preview@example.com",
            resetCredits: ResetCredits(availableCount: 2, earliestExpiry: now.addingTimeInterval(12 * 86_400)),
            tokensToday: 864_000, fetchedAt: fallback ? now.addingTimeInterval(-7200) : now,
            sourceNote: fallback ? "Session log from two hours ago. Live request: token expired. Run codex to refresh sign-in." : nil)
        return [.claude: ProviderStatus(snapshot: claude), .codex: ProviderStatus(snapshot: codex)]
    }

    static func history(now: Date = Date()) -> [HistoryRecord] {
        (0..<193).flatMap { index -> [HistoryRecord] in
            let at = now.addingTimeInterval(Double(index - 192) * 900)
            return ProviderKind.allCases.map { provider in
                let shift = provider == .claude ? 0 : 7
                return HistoryRecord(at: at, provider: provider.rawValue,
                                     session: Double((index + shift) % 20) * 4.7,
                                     weekly: 22 + Double(index) * (provider == .claude ? 0.20 : 0.30),
                                     tokensToday: (Calendar.current.component(.hour, from: at) * 4
                                                   + Calendar.current.component(.minute, from: at) / 15) * 13_000)
            }
        }
    }
}
