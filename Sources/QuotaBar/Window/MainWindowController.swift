import AppKit
import SwiftUI
import Combine

// Window and sidebar layout adapted from Claude-Usage-Tracker (THIRD_PARTY_NOTICES).
@MainActor
final class MainWindowController: NSWindowController {
    private var languageSubscription: AnyCancellable?
    init(store: UsageStore, model: SettingsModel, notifications: UsageNotifications) {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 750),
                                    styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("QuotaBar Settings")
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: SettingsRootView()
            .environmentObject(store).environmentObject(model).environmentObject(notifications))
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 10
        window.contentView?.layer?.masksToBounds = true
        window.center()
        super.init(window: window)
        languageSubscription = model.$settings.map(\.language).removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak window] _ in window?.title = L("QuotaBar Settings") }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
        } else { super.keyDown(with: event) }
    }
}

enum SettingsSection: String, CaseIterable {
    case account, appearance, general, history, app, popover, diagnostics
    var title: String {
        switch self {
        case .account: return L("Account")
        case .appearance: return L("Appearance")
        case .general: return L("General")
        case .history: return L("History")
        case .app: return L("App Settings")
        case .popover: return L("Popover")
        case .diagnostics: return L("Diagnostics")
        }
    }
    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .appearance: return "paintbrush.fill"
        case .general: return "gearshape"
        case .history: return "chart.bar.xaxis"
        case .app: return "app.badge"
        case .popover: return "rectangle.topthird.inset.filled"
        case .diagnostics: return "ant"
        }
    }
}

private struct SettingsRootView: View {
    @EnvironmentObject private var model: SettingsModel
    @EnvironmentObject private var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    WindowControl(minimize: false)
                    WindowControl(minimize: true)
                    Spacer()
                }.padding(.top, 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("ACTIVE PROVIDER")).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
                    Picker(L("Active provider"), selection: $model.selectedProvider) {
                        ForEach(ProviderKind.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }.labelsHidden().pickerStyle(.menu)
                    Divider().padding(.vertical, 6)
                    sectionLabel("ACCOUNTS")
                    ForEach(ProviderKind.allCases, id: \.self) { provider in
                        Button {
                            model.selectedProvider = provider
                            model.page = .account
                        } label: {
                            HStack(spacing: 8) {
                                ProviderMark(provider: provider).frame(width: 14)
                                Text(provider.displayName)
                                Spacer()
                                StatusDot(status: store.statuses[provider] ?? ProviderStatus())
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(selectionBackground(model.page == .account && model.selectedProvider == provider))
                            .foregroundColor(model.page == .account && model.selectedProvider == provider ? .white : .primary)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Divider().padding(.vertical, 6)
                    sectionLabel("SETTINGS")
                    ForEach([SettingsSection.appearance, .general, .history], id: \.self) { sidebarButton($0) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(CardColors.background))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CardColors.border, lineWidth: 0.5))
                Spacer()
                sectionLabel("APP")
                sidebarButton(.app)
                sidebarButton(.popover)
                Divider().padding(.top, 4)
                HStack {
                    Button { model.page = .diagnostics } label: { Image(systemName: "ant") }
                        .help(L("Diagnostics")).accessibilityLabel(L("Diagnostics"))
                    Spacer()
                    Text("QuotaBar").font(.system(size: 10, weight: .medium))
                    Spacer()
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                        .help(L("Quit QuotaBar")).accessibilityLabel(L("Quit QuotaBar"))
                }.buttonStyle(.plain).foregroundColor(.secondary).padding(.vertical, 8)
            }
            .padding(.horizontal, 12).padding(.bottom, 4)
            .frame(width: 190)
            .background(MaterialBackground(sidebar: true))
            Group {
                switch model.page {
                case .account: AccountPage()
                case .appearance: AppearancePage()
                case .general: GeneralPage()
                case .history: HistoryPage()
                case .app: AppSettingsPage()
                case .popover: PopoverSettingsPage()
                case .diagnostics: DiagnosticsPage()
                }
            }
            .frame(width: 530, height: 750)
            .clipped()
            .background(colorScheme == .dark ? Color.black.opacity(0.15) : Color.white.opacity(0.30))
        }
        .frame(width: 720, height: 750)
        .background(MaterialBackground())
        .environment(\.locale, model.settings.language.locale)
        .id(model.settings.language)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(L(title)).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func selectionBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : .clear)
    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        Button { model.page = section } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon).frame(width: 14)
                Text(section.title)
                Spacer()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(model.page == section ? .white : .primary)
            .padding(.horizontal, 8).frame(height: 26)
            .background(selectionBackground(model.page == section))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct WindowControl: View {
    let minimize: Bool
    @State private var hovered = false
    var body: some View {
        Button {
            if minimize { NSApp.keyWindow?.miniaturize(nil) } else { NSApp.keyWindow?.close() }
        } label: {
            Circle().fill(minimize ? Color(red: 1, green: 0.74, blue: 0.18) : Color(red: 1, green: 0.38, blue: 0.34))
                .frame(width: 12, height: 12)
                .overlay {
                    if hovered {
                        Image(systemName: minimize ? "minus" : "xmark")
                            .font(.system(size: 7, weight: .bold)).foregroundColor(.black.opacity(0.5))
                    }
                }
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityLabel(L(minimize ? "Minimize window" : "Close window"))
    }
}
