import AppKit
import SwiftUI
import UserNotifications

struct AppearancePage: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        SettingsPage(title: "Appearance", subtitle: "Customize how Claude and Codex appear in your menu bar") {
            SettingsCard("Live preview", subtitle: "Example usage · Claude 39% · Codex 60%") {
                Image(nsImage: StatusTitleImage.make(statuses: PreviewData.statuses(), settings: model.settings,
                                                     mode: model.displayMode))
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .accessibilityLabel(L("Menu bar style preview"))
            }
            SettingsCard("Global Settings", subtitle: "Applies to both providers") {
                VStack(spacing: 16) {
                    SettingRow(title: "Appearance", detail: "Match your desktop or choose a theme.") {
                        Picker(L("Appearance"), selection: $model.settings.theme) {
                            ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 130)
                    }
                    Divider()
                    SettingRow(title: "Indicator colors", detail: "Usage colors reflect the quota consumed.") {
                        Picker(L("Indicator colors"), selection: $model.settings.colorMode) {
                            ForEach(IndicatorColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 130)
                    }
                    settingToggle("Show provider labels", "Claude · Codex", $model.settings.showLabels)
                    settingToggle("Show remaining percentage", "Display how much quota is available.", $model.showRemaining)
                }
            }
            SettingsCard("Menu Bar Metrics", subtitle: "Both providers stay visible side by side") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(L("Icon Style"), systemImage: "menubar.rectangle").font(Typography.body)
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(MenuBarStyle.allCases, id: \.self) { style in
                            Button { model.settings.menuBarStyle = style } label: {
                                VStack(spacing: 7) {
                                    Image(nsImage: styleImage(style)).resizable().scaledToFit().frame(width: 54, height: 24)
                                        .frame(maxWidth: .infinity).frame(height: 48)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(model.settings.menuBarStyle == style ? Color.accentColor : CardColors.border,
                                                          lineWidth: model.settings.menuBarStyle == style ? 2 : 0.5))
                                    Text(style.title).font(.system(size: 9)).multilineTextAlignment(.center).frame(height: 24)
                                }.frame(maxWidth: .infinity)
                            }.buttonStyle(.plain).accessibilityLabel(L("%@ icon style", style.title))
                                .accessibilityAddTraits(model.settings.menuBarStyle == style ? .isSelected : [])
                        }
                    }
                    Text(L("Claude shows the session window. Codex shows the session window, or weekly usage when a session window is unavailable."))
                        .font(Typography.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func styleImage(_ style: MenuBarStyle) -> NSImage {
        var settings = model.settings
        settings.menuBarStyle = style
        settings.showLabels = false
        return StatusTitleImage.make(statuses: PreviewData.statuses(), settings: settings, mode: model.displayMode)
    }
}

struct GeneralPage: View {
    @EnvironmentObject private var model: SettingsModel
    @EnvironmentObject private var notifications: UsageNotifications
    @State private var thresholdText = ""
    @State private var thresholdError: String?
    @State private var requestingPermission = false

    var body: some View {
        SettingsPage(title: "General", subtitle: "Refresh preferences and quota notifications") {
            SettingsCard("Refresh Interval", subtitle: "Choose how often usage is checked") {
                SettingRow(title: "Refresh every", detail: "Temporary rate limits delay automatic retries.") {
                    Picker(L("Refresh interval"), selection: $model.settings.refreshInterval) {
                        ForEach(Settings.refreshIntervalChoices, id: \.self) { seconds in
                            Text(L(seconds == 60 ? "%d minute" : "%d minutes", Int(seconds / 60))).tag(seconds)
                        }
                    }.labelsHidden().frame(width: 130)
                }
            }
            SettingsCard("Notifications", subtitle: "Alerts for Claude and Codex session and weekly limits") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingRow(title: "Enable notifications", detail: permissionDescription) {
                        Toggle(L("Enable notifications"), isOn: Binding(
                            get: { model.settings.notificationsEnabled },
                            set: { enableNotifications($0) }))
                            .labelsHidden().toggleStyle(.switch).disabled(requestingPermission)
                    }
                    if notifications.permission == .denied {
                        Button(L("Open Notification Settings")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    if let error = notifications.errorMessage {
                        Text(L(error)).font(Typography.caption).foregroundColor(.orange)
                    }
                    Divider()
                    Text(L("Alert thresholds")).font(Typography.body)
                    ForEach(model.settings.notificationThresholds.sorted(), id: \.self) { threshold in
                        HStack(spacing: 8) {
                            Circle().fill(Color(nsColor: StatusTitleImage.color(used: Double(threshold), mode: .usage)))
                                .frame(width: 7, height: 7)
                            Text("\(threshold)%").font(.system(size: 12, weight: .semibold)).frame(width: 34, alignment: .leading)
                            Text(L("Quota consumed")).font(Typography.caption).foregroundColor(.secondary)
                            Spacer()
                            Button { model.settings.notificationThresholds.removeAll { $0 == threshold } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.plain).accessibilityLabel(L("Remove %d percent threshold", threshold))
                        }
                    }
                    HStack {
                        TextField("1–100", text: $thresholdText).frame(width: 64)
                            .accessibilityLabel(L("Custom notification threshold"))
                            .onSubmit { addThreshold() }
                        Text("%").foregroundColor(.secondary)
                        Button(L("Add threshold"), action: addThreshold)
                        Spacer()
                    }
                    if let error = thresholdError { Text(L(error)).font(Typography.caption).foregroundColor(.orange) }
                    if model.settings.notificationThresholds.isEmpty {
                        Text(L("Add a threshold to receive usage alerts.")).font(Typography.caption).foregroundColor(.secondary)
                    }
                    Divider()
                    settingToggle("Quota reset alerts", "Notify when a new session or weekly window is observed.", $model.settings.notifyOnReset)
                    settingToggle("Notification sound", "Play the default alert sound.", $model.settings.notificationSound)
                }
            }
        }.task { await notifications.refreshPermission() }
    }

    private var permissionDescription: String {
        switch notifications.permission {
        case .denied: return L("Notifications are blocked in macOS Settings.")
        case .authorized, .provisional: return L("Each threshold alerts once per quota window.")
        default: return L("macOS will ask for permission when enabled.")
        }
    }

    private func enableNotifications(_ enabled: Bool) {
        if !enabled { model.settings.notificationsEnabled = false; return }
        requestingPermission = true
        Task {
            let granted = await notifications.requestPermission()
            model.settings.notificationsEnabled = granted
            requestingPermission = false
        }
    }

    private func addThreshold() {
        guard let value = Int(thresholdText.trimmingCharacters(in: .whitespaces)), (1...100).contains(value) else {
            thresholdError = "Enter a whole percentage from 1 to 100."
            return
        }
        guard !model.settings.notificationThresholds.contains(value) else {
            thresholdError = "This threshold is already enabled."
            return
        }
        model.settings.notificationThresholds.append(value)
        thresholdText = ""
        thresholdError = nil
    }
}

struct PopoverSettingsPage: View {
    @EnvironmentObject private var model: SettingsModel
    var body: some View {
        SettingsPage(title: "Popover", subtitle: "Choose the details shown when you open the menu bar") {
            SettingsCard("Reset Time") {
                SettingRow(title: "Display format", detail: "Show when quota resets or the time remaining.") {
                    Picker(L("Reset time format"), selection: $model.settings.timeDisplay) {
                        ForEach(ResetTimeDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 140)
                }
            }
            SettingsCard("Usage Details") {
                VStack(spacing: 16) {
                    settingToggle("Per-model usage", "Show additional model limits reported by Claude.", $model.settings.showModels)
                    Divider()
                    settingToggle("Today's tokens", "Show tokens counted from this Mac's conversations.", $model.settings.showTokens)
                    Divider()
                    settingToggle("Codex full resets", "Show available reset count and earliest expiry.", $model.settings.showResetCredits)
                }
            }
        }
    }
}

struct AppSettingsPage: View {
    @EnvironmentObject private var model: SettingsModel
    @EnvironmentObject private var store: UsageStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchFailed = false
    var body: some View {
        SettingsPage(title: "App Settings", subtitle: "QuotaBar on your Mac") {
            SettingsCard("Language", subtitle: "Changes apply immediately and are saved for the next launch.") {
                SettingRow(title: "Language", detail: "Choose your preferred language.") {
                    Picker(L("Language"), selection: $model.settings.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 140)
                }
            }
            SettingsCard("Startup") {
                SettingRow(title: "Launch at login",
                           detail: launchFailed ? "Check System Settings › General › Login Items."
                           : "Keep Claude and Codex usage in your menu bar.",
                           detailColor: launchFailed ? .orange : .secondary) {
                    Toggle(L("Launch at login"), isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                        .disabled(store.isPreview)
                        .onChange(of: launchAtLogin) { wanted in
                            let actual = LaunchAtLogin.set(wanted)
                            launchFailed = actual != wanted
                            launchAtLogin = actual
                        }
                }
            }
            SettingsCard("QuotaBar", subtitle: "Claude and Codex usage, together") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Your usage history stays on this Mac.")).font(Typography.body)
                    Text(L("Account credentials are read from your signed-in command-line tools. Sign in there to reconnect an account."))
                        .font(Typography.caption).foregroundColor(.secondary)
                    if store.isPreview { Label(L("Preview data · preferences are temporary"), systemImage: "eye").font(Typography.caption) }
                }
            }
        }
    }
}

struct AccountPage: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var model: SettingsModel
    private var provider: ProviderKind { model.selectedProvider }
    private var status: ProviderStatus { store.statuses[provider] ?? ProviderStatus() }
    var body: some View {
        SettingsPage(title: L("%@ Account", provider.displayName), subtitle: "Usage from your current CLI account") {
            SettingsCard {
                HStack(spacing: 10) {
                    ProviderMark(provider: provider).font(.system(size: 22)).foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.snapshot?.accountLabel ?? provider.displayName).font(Typography.subtitle).textSelection(.enabled)
                        Text(L(status.errorMessage != nil ? "Connection needs attention"
                             : status.snapshot?.sourceNote != nil ? "Showing saved usage"
                             : status.snapshot != nil ? "Connected" : "Waiting for sign-in"))
                            .font(Typography.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    StatusDot(status: status)
                }
            }
            if let error = status.localizedErrorMessage {
                SettingsCard("Connection status") { Text(error).font(Typography.body).foregroundColor(.orange).textSelection(.enabled) }
            }
            if let note = status.snapshot?.sourceNote {
                SettingsCard("Saved usage", subtitle: "The last recorded usage is shown while the live request is unavailable.") {
                    Text(L(note)).font(Typography.caption).foregroundColor(.orange).textSelection(.enabled)
                }
            }
            SettingsCard("Connection", subtitle: L("Sign in through the %@ CLI", provider.displayName)) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L(provider == .claude ? "Open Terminal, run claude, and complete sign-in."
                         : "Open Terminal and run codex login. For an expired session, run codex to refresh sign-in."))
                        .font(Typography.body)
                    HStack {
                        Text(provider == .claude ? "claude" : "codex login")
                            .font(Typography.monospaced).textSelection(.enabled)
                        Spacer()
                        Button(L("Refresh usage")) { Task { await store.refresh(force: true) } }
                            .disabled(status.isLoading || store.isPreview)
                    }
                }
            }
            if let snapshot = status.snapshot {
                SettingsCard("Latest update") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let plan = snapshot.planLabel { Text(L("Plan · %@", plan)).font(Typography.body) }
                        Text(Format.dateTime(snapshot.fetchedAt))
                            .font(Typography.caption).foregroundColor(.secondary)
                        if store.isPreview { Text(L("Preview data")).font(Typography.caption).foregroundColor(.orange) }
                    }
                }
            }
        }
    }
}

private func settingToggle(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
    SettingRow(title: title, detail: detail) {
        Toggle(L(title), isOn: binding).labelsHidden().toggleStyle(.switch)
    }
}

struct DiagnosticsPage: View {
    @EnvironmentObject private var store: UsageStore
    @State private var rawOutput = ""
    @State private var fetching = false

    var body: some View {
        SettingsPage(title: "Diagnostics", subtitle: "What the usage APIs actually answered") {
            SettingsCard("Raw responses",
                         subtitle: "The same output as `QuotaBar --once --raw`. Includes the signed-in account email.") {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack {
                        Button(L(fetching ? "Fetching…" : "Fetch")) { fetch() }
                            .disabled(fetching || store.isPreview)
                        if !rawOutput.isEmpty {
                            Button(L("Copy")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(rawOutput, forType: .string)
                            }
                        }
                        Spacer()
                    }
                    if !rawOutput.isEmpty {
                        ScrollView {
                            Text(rawOutput)
                                .font(Typography.monospaced)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Spacing.sm)
                        }
                        .frame(height: 240)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private func fetch() {
        fetching = true
        Task {
            async let claude = (try? await ClaudeProvider().fetchRawJSON()) ?? "unavailable"
            async let codex = (try? await CodexProvider().fetchRawJSON()) ?? "unavailable"
            let text = "=== Claude\n\(await claude)\n\n=== Codex\n\(await codex)"
            await MainActor.run {
                rawOutput = text
                fetching = false
            }
        }
    }
}
