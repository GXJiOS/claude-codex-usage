import Foundation
import UserNotifications
import Combine

/// Tracks each account and quota window independently, using API reset dates as cycle boundaries.
struct UsageNotificationPolicy: Codable {
    struct WindowState: Codable {
        var resetAt: Date?
        var fetchedAt: Date
        var used: Double
        var highestDeliveredThreshold = 0
        var resetPending = false
    }

    struct Event: Equatable {
        let key: String
        let provider: ProviderKind
        let window: String
        let resetAt: Date?
        let threshold: Int?
        let used: Double

        var id: String {
            "quotabar.\(key).\(resetAt?.timeIntervalSince1970 ?? 0).\(threshold.map(String.init) ?? "reset")"
        }
        var title: String {
            L(threshold == nil ? "%@ · %@ reset" : "%@ · %@ usage", provider.displayName, L(window))
        }
        var body: String {
            if threshold == nil { return L("A new quota window is available.") }
            let suffix = resetAt.map { L(" Resets %@.", Format.dateTime($0)) } ?? ""
            return L("%d%% of your %@ quota is used.", Int(used.rounded()), L(window).lowercased()) + suffix
        }
    }

    private(set) var states: [String: WindowState] = [:]

    mutating func evaluate(provider: ProviderKind, snapshot: UsageSnapshot, settings: Settings,
                           now: Date = Date()) -> [Event] {
        guard settings.notificationsEnabled, snapshot.sourceNote == nil,
              snapshot.fetchedAt <= now.addingTimeInterval(30),
              now.timeIntervalSince(snapshot.fetchedAt) <= max(600, settings.refreshInterval * 2) else { return [] }
        states = states.filter { now.timeIntervalSince($0.value.fetchedAt) < 40 * 86_400 }
        let windows: [(String, UsageWindow?)] = [("Session", snapshot.session), ("Weekly", snapshot.weekly)]
        var events: [Event] = []
        for (label, window) in windows {
            guard let window, window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else { continue }
            let key = "\(provider.rawValue)|\(snapshot.accountLabel ?? "current")|\(label)"
            let previous = states[key]
            if let previous, snapshot.fetchedAt < previous.fetchedAt { continue }
            let newCycle: Bool
            if let oldReset = previous?.resetAt, let newReset = window.resetsAt {
                newCycle = newReset > oldReset && snapshot.fetchedAt >= oldReset
            } else { newCycle = false }
            var state = previous ?? WindowState(resetAt: window.resetsAt, fetchedAt: snapshot.fetchedAt, used: window.usedPercent)
            if newCycle {
                state.highestDeliveredThreshold = 0
                state.resetPending = settings.notifyOnReset && (previous?.used ?? 0) > 0
            }
            if !settings.notifyOnReset { state.resetPending = false }
            state.resetAt = window.resetsAt
            state.fetchedAt = snapshot.fetchedAt
            state.used = window.usedPercent
            states[key] = state
            if state.resetPending {
                events.append(Event(key: key, provider: provider, window: label,
                                    resetAt: state.resetAt, threshold: nil, used: state.used))
            }
            let threshold = settings.notificationThresholds.filter {
                (1...100).contains($0) && Double($0) <= state.used && $0 > state.highestDeliveredThreshold
            }.max()
            if let threshold {
                events.append(Event(key: key, provider: provider, window: label,
                                    resetAt: state.resetAt, threshold: threshold, used: state.used))
            }
        }
        return events
    }

    mutating func markDelivered(_ event: Event) {
        guard var state = states[event.key], state.resetAt == event.resetAt else { return }
        if let threshold = event.threshold {
            state.highestDeliveredThreshold = max(state.highestDeliveredThreshold, threshold)
        } else { state.resetPending = false }
        states[event.key] = state
    }
}

@MainActor
final class UsageNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
    @Published private(set) var errorMessage: String?
    private var policy: UsageNotificationPolicy
    private var pending = Set<String>()
    private let defaults: UserDefaults
    private let enabled: Bool
    private let storageKey = "usageNotificationPolicy.v1"

    init(defaults: UserDefaults = .standard, enabled: Bool = true) {
        self.defaults = defaults
        self.enabled = enabled
        policy = defaults.data(forKey: "usageNotificationPolicy.v1")
            .flatMap { try? JSONDecoder().decode(UsageNotificationPolicy.self, from: $0) } ?? UsageNotificationPolicy()
        super.init()
    }

    func start() {
        guard enabled else { return }
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshPermission() }
    }

    func refreshPermission() async {
        guard enabled else { return }
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestPermission() async -> Bool {
        guard enabled else { errorMessage = "Notifications are disabled in preview mode."; return false }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshPermission()
            return granted
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func process(provider: ProviderKind, snapshot: UsageSnapshot, settings: Settings) async {
        guard enabled, settings.notificationsEnabled else { return }
        await refreshPermission()
        guard permission == .authorized || permission == .provisional else { return }
        let events = policy.evaluate(provider: provider, snapshot: snapshot, settings: settings)
        for event in events where !pending.contains(event.id) {
            pending.insert(event.id)
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = settings.notificationSound ? .default : nil
            do {
                try await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
                policy.markDelivered(event)
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
            pending.remove(event.id)
        }
        if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: storageKey) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
