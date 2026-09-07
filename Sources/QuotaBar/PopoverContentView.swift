import AppKit
import SwiftUI

// Card layout adapted from Claude-Usage-Tracker (THIRD_PARTY_NOTICES).
struct PopoverContentView: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var model: SettingsModel
    @State private var contentHeight: CGFloat = 260
    let onSettings: () -> Void
    var onResize: () -> Void = {}

    private var provider: ProviderKind { model.selectedProvider }
    private var status: ProviderStatus { store.statuses[provider] ?? ProviderStatus() }
    private var maxContentHeight: CGFloat {
        max(160, min(650, (NSScreen.main?.visibleFrame.height ?? 800) - 180))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Menu {
                        ForEach(ProviderKind.allCases, id: \.self) { kind in
                            Button { model.selectedProvider = kind } label: {
                                Label(kind.displayName, systemImage: kind == provider ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(provider.displayName).font(.system(size: 14, weight: .bold))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("Select provider"))
                    HStack(spacing: 4) {
                        StatusDot(status: status)
                        Text(L(store.isPreview ? "Preview data" : status.isLoading ? "Refreshing…"
                             : status.errorMessage != nil ? "Connection needs attention"
                             : status.snapshot?.sourceNote != nil ? "Saved usage"
                             : status.snapshot != nil ? "Connected" : "Waiting for usage"))
                            .font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button { Task { await store.refresh(force: true) } } label: {
                    if status.isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(status.isLoading || store.isPreview)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel(L("Refresh usage")).help(L("Refresh usage"))
                Button(action: onSettings) { Image(systemName: "gearshape.fill") }
                    .keyboardShortcut(",", modifiers: .command)
                    .accessibilityLabel(L("Open settings")).help(L("Settings"))
            }
            .buttonStyle(.plain).foregroundColor(.primary)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider().padding(.horizontal, 16)
            ScrollView {
                dashboard
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onAppear { updateHeight(geometry.size.height) }
                            .onChange(of: geometry.size.height) { updateHeight($0) }
                    })
            }
            .scrollIndicators(.hidden)
            .frame(height: min(contentHeight, maxContentHeight))
            Divider().padding(.horizontal, 16)
            HStack {
                Text(L(model.showRemaining ? "Remaining quota" : "Used quota"))
                Spacer()
                if let date = status.snapshot?.fetchedAt {
                    Text(L("Updated %@", Format.time(date)))
                }
            }
            .font(.system(size: 9)).foregroundColor(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .background(MaterialBackground())
        .environment(\.locale, model.settings.language.locale)
        .id(model.settings.language)
        .preferredColorScheme(model.settings.theme == .system ? nil : model.settings.theme == .dark ? .dark : .light)
    }

    private func updateHeight(_ height: CGFloat) {
        guard height > 0, abs(contentHeight - height) > 0.5 else { return }
        contentHeight = height
        DispatchQueue.main.async { onResize() }
    }

    @ViewBuilder private var dashboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = status.localizedErrorMessage {
                banner(message, symbol: "exclamationmark.triangle.fill")
            }
            if let snapshot = status.snapshot {
                if snapshot.sourceNote != nil {
                    banner(L("Saved usage · updated %@", Format.dateTime(snapshot.fetchedAt)), symbol: "clock.arrow.circlepath")
                } else if Date().timeIntervalSince(snapshot.fetchedAt) > max(300, model.settings.refreshInterval * 2) {
                    banner(L("Last successful update: %@", Format.dateTime(snapshot.fetchedAt)),
                           symbol: "clock")
                }
                if let account = snapshot.accountLabel {
                    Text(account).font(.system(size: 10)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(account).padding(.bottom, 2)
                }
                UsageCard(title: L("Session Usage"), subtitle: L("Session window"), window: snapshot.session)
                UsageCard(title: L("All models"), tag: L("Weekly"), window: snapshot.weekly)
                if model.settings.showModels {
                    ForEach(Array(snapshot.extras.enumerated()), id: \.offset) { _, extra in
                        UsageCard(title: extra.label, tag: L("Weekly"), window: extra.window)
                    }
                }
                if model.settings.showTokens, let tokens = snapshot.tokensToday {
                    detailCard(title: "Today's tokens", value: Format.tokens(tokens), subtitle: "From this Mac's conversations")
                }
                if model.settings.showResetCredits, let credits = snapshot.resetCredits {
                    detailCard(title: "Full resets", value: "\(credits.availableCount)",
                               subtitle: credits.earliestExpiry.map { L("Earliest expiry: %@", Format.shortDate($0)) } ?? "Available quota resets")
                }
                if let plan = snapshot.planLabel {
                    Text(plan).font(.system(size: 9, weight: .semibold)).foregroundColor(.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .padding(.top, 2)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: status.isLoading ? "arrow.triangle.2.circlepath" : "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 24)).foregroundColor(.secondary)
                    Text(status.isLoading ? L("Loading usage…") : L("Connect %@", provider.displayName))
                        .font(.system(size: 13, weight: .medium))
                    Text(L("Usage appears after signing in to the %@ CLI.", provider.displayName))
                        .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button(L("Account settings")) { model.page = .account; onSettings() }
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
    }

    private func banner(_ message: String, symbol: String) -> some View {
        Button { model.page = .account; onSettings() } label: {
            Label(message, systemImage: symbol)
                .font(.system(size: 10)).foregroundColor(.orange)
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.10)))
        }.buttonStyle(.plain).help(message)
    }

    private func detailCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L(title)).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            Text(L(subtitle)).font(.system(size: 10)).foregroundColor(.secondary)
        }.padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

private struct UsageCard: View {
    @EnvironmentObject private var model: SettingsModel
    let title: String
    var tag: String? = nil
    var subtitle: String? = nil
    let window: UsageWindow?

    private var amount: Double? {
        guard let used = window?.usedPercent, used.isFinite else { return nil }
        return min(100, max(0, model.displayMode.value(usedPercent: used)))
    }
    private var tint: Color {
        Color(nsColor: StatusTitleImage.color(used: window?.usedPercent ?? 0, mode: model.settings.colorMode,
                                              thresholds: model.settings.usageColorThresholds))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        if let tag {
                            Text(tag).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    if let subtitle { Text(L(subtitle)).font(.system(size: 10)).foregroundColor(.secondary) }
                }
                Spacer(minLength: 2)
                Text(amount.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(amount == nil ? .secondary : tint)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint).frame(width: geometry.size.width * (amount ?? 0) / 100)
                }
            }.frame(height: 4).accessibilityHidden(true)
            if let reset = window?.resetsAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(resetText(reset, now: context.date)).font(.system(size: 9)).foregroundColor(.secondary)
                }
            } else {
                Text(L(window == nil ? "Not reported by this account" : "Reset time unavailable"))
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func resetText(_ reset: Date, now: Date) -> String {
        guard reset > now else { return L("Reset due · refresh to update") }
        let absolute = Format.dateTime(reset)
        let duration = Format.countdown(reset.timeIntervalSince(now))
        switch model.settings.timeDisplay {
        case .resetTime: return L("Resets %@", absolute)
        case .countdown: return L("Resets in %@", duration)
        case .both:
            let date = reset.timeIntervalSince(now) >= 86_400 ? absolute : Format.time(reset)
            return L("Resets in %@ (%@)", duration, date)
        }
    }
}
