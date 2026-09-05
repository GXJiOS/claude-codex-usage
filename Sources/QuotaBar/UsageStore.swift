import Foundation

/// Owns the latest numbers for every provider, polls on a timer, and backs off
/// per provider when a usage API answers 429.
@MainActor
final class UsageStore {
    static let refreshInterval: TimeInterval = 300
    /// Re-fetch when the menu opens and the data is older than this.
    static let staleAfter: TimeInterval = 60
    private static let backoffBase: TimeInterval = 10 * 60
    private static let backoffMax: TimeInterval = 60 * 60

    private let providers: [any UsageProvider]
    private(set) var statuses: [ProviderKind: ProviderStatus] = [:]
    private(set) var lastRefresh: Date?
    private var backoffUntil: [ProviderKind: Date] = [:]
    private var backoffStep: [ProviderKind: Int] = [:]
    private var pollTask: Task<Void, Never>?
    private var refreshing = false

    var onChange: (() -> Void)?

    init(providers: [any UsageProvider]) {
        self.providers = providers
        for provider in providers {
            statuses[provider.kind] = ProviderStatus()
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(force: false)
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
            }
        }
    }

    func refreshIfStale() {
        guard !refreshing else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.staleAfter { return }
        Task { await refresh(force: false) }
    }

    func refresh(force: Bool) async {
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
        onChange?()

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
        onChange?()
    }

    private func apply(_ kind: ProviderKind, _ result: Result<UsageSnapshot, Error>) {
        var status = statuses[kind] ?? ProviderStatus()
        status.isLoading = false
        switch result {
        case .success(let snapshot):
            status.snapshot = snapshot
            status.errorMessage = nil
            backoffUntil[kind] = nil
            backoffStep[kind] = 0
        case .failure(let error):
            if case ProviderError.rateLimited = error {
                let step = backoffStep[kind, default: 0]
                let delay = min(Self.backoffBase * pow(2, Double(step)), Self.backoffMax)
                let until = Date(timeIntervalSinceNow: delay)
                backoffUntil[kind] = until
                backoffStep[kind] = step + 1
                status.errorMessage = "Rate limited; next try \(Format.time(until))"
            } else {
                status.errorMessage = error.localizedDescription
            }
        }
        statuses[kind] = status
    }
}
