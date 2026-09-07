import Foundation
import Combine

/// Owns the latest numbers for every provider, polls on a timer, and backs off
/// per provider when a usage API answers 429.
@MainActor
final class UsageStore: ObservableObject {
    /// Re-fetch when the menu opens and the data is older than this.
    static let staleAfter: TimeInterval = 60
    private static let backoffBase: TimeInterval = 10 * 60
    private static let backoffMax: TimeInterval = 60 * 60

    private let providers: [any UsageProvider]
    @Published private(set) var statuses: [ProviderKind: ProviderStatus] = [:]
    @Published private(set) var lastRefresh: Date?
    let isPreview: Bool
    private var backoffUntil: [ProviderKind: Date] = [:]
    private var backoffStep: [ProviderKind: Int] = [:]
    private var pollTask: Task<Void, Never>?
    private var refreshing = false
    private var settings = Settings.load()
    private var settingsObserver: NSObjectProtocol?
    private let history = HistoryRecorder()

    var onFreshSnapshot: ((ProviderKind, UsageSnapshot) -> Void)?

    init(providers: [any UsageProvider], preview: [ProviderKind: ProviderStatus]? = nil) {
        self.providers = providers
        isPreview = preview != nil
        for provider in providers {
            statuses[provider.kind] = ProviderStatus()
        }
        if let preview { statuses = preview }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .quotaBarSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// Re-arms the timer when the interval changed, without spending a fetch on a settings edit.
    private func applySettings() {
        guard !isPreview else { return }
        let updated = Settings.load()
        let intervalChanged = updated.refreshInterval != settings.refreshInterval
        settings = updated
        if intervalChanged { arm(refreshFirst: false) }
    }

    func startPolling() {
        guard !isPreview else { return }
        arm(refreshFirst: true)
    }

    private func arm(refreshFirst: Bool) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var shouldRefresh = refreshFirst
            while !Task.isCancelled {
                guard let self else { return }
                if shouldRefresh { await self.refresh(force: false) }
                shouldRefresh = true
                try? await Task.sleep(nanoseconds: UInt64(self.settings.refreshInterval * 1_000_000_000))
            }
        }
    }

    func refreshIfStale() {
        guard !refreshing else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.staleAfter { return }
        Task { await refresh(force: false) }
    }

    func refresh(force: Bool) async {
        guard !isPreview else { return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        struct Outcome: Sendable {
            let kind: ProviderKind
            let result: Result<UsageSnapshot, Error>
        }

        var started: [ProviderKind] = []
        for provider in providers {
            if !force, let until = backoffUntil[provider.kind], until > Date() { continue }
            statuses[provider.kind]?.isLoading = true
            started.append(provider.kind)
        }

        await withTaskGroup(of: Outcome.self) { group in
            for provider in providers where started.contains(provider.kind) {
                group.addTask {
                    do {
                        return Outcome(kind: provider.kind, result: .success(try await provider.fetch()))
                    } catch {
                        return Outcome(kind: provider.kind, result: .failure(error))
                    }
                }
            }
            for await outcome in group {
                apply(outcome.kind, outcome.result)
            }
        }

        lastRefresh = Date()
        history.record(statuses)
    }

    private func apply(_ kind: ProviderKind, _ result: Result<UsageSnapshot, Error>) {
        var status = statuses[kind] ?? ProviderStatus()
        status.isLoading = false
        switch result {
        case .success(let snapshot):
            status.snapshot = snapshot
            status.errorMessage = nil
            status.providerError = nil
            status.retryAt = nil
            backoffUntil[kind] = nil
            backoffStep[kind] = 0
            if snapshot.sourceNote == nil { onFreshSnapshot?(kind, snapshot) }
        case .failure(let error):
            status.providerError = error as? ProviderError
            status.retryAt = nil
            if case ProviderError.rateLimited = error {
                let step = backoffStep[kind, default: 0]
                let delay = min(Self.backoffBase * pow(2, Double(step)), Self.backoffMax)
                let until = Date(timeIntervalSinceNow: delay)
                backoffUntil[kind] = until
                backoffStep[kind] = step + 1
                status.errorMessage = "Rate limited; next try \(Format.time(until))"
                status.retryAt = until
            } else {
                status.errorMessage = error.localizedDescription
            }
        }
        statuses[kind] = status
    }
}
