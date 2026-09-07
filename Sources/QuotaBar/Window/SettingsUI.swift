import AppKit
import SwiftUI

// Adapted from Claude-Usage-Tracker. See THIRD_PARTY_NOTICES for the MIT license.

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let cardSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let contentPadding: CGFloat = 20
    static let radiusLarge: CGFloat = 8
}

enum Typography {
    static let title: Font = .system(size: 18, weight: .semibold)
    static let subtitle: Font = .system(size: 14, weight: .semibold)
    static let body: Font = .system(size: 13, weight: .regular)
    static let caption: Font = .system(size: 11, weight: .regular)
    static let monospaced: Font = .system(size: 11, design: .monospaced)
}

enum CardColors {
    static let background = Color.primary.opacity(0.04)
    static let border = Color.primary.opacity(0.08)
}

/// Rounded container with an optional title/subtitle band above its content.
struct SettingsCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    let content: Content

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if let title {
                        Text(L(title)).font(Typography.subtitle)
                    }
                    if let subtitle {
                        Text(L(subtitle))
                            .font(Typography.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Spacing.cardPadding)
                .padding(.top, Spacing.cardPadding)
                .padding(.bottom, Spacing.md)
            }
            content
                .padding(.top, title == nil && subtitle == nil ? Spacing.cardPadding : 0)
                .padding(.horizontal, Spacing.cardPadding)
                .padding(.bottom, Spacing.cardPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Spacing.radiusLarge).fill(CardColors.background))
        .overlay(RoundedRectangle(cornerRadius: Spacing.radiusLarge)
            .strokeBorder(CardColors.border, lineWidth: 0.5))
    }
}

/// Large title and one line of explanation at the top of a page.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(title)).font(Typography.title)
            Text(L(subtitle)).font(Typography.caption).foregroundColor(.secondary)
        }
    }
}

/// One card row: name over a dimmed explanation, control pinned right.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    var detailColor: Color = .secondary
    var monospacedDetail = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(L(title)).font(Typography.body)
                Text(L(detail))
                    .font(monospacedDetail ? Typography.monospaced : Typography.caption)
                    .foregroundColor(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control()
        }
        .frame(minHeight: 34)
    }
}

/// Page scaffold: header, then cards down the page.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.cardSpacing) {
                PageHeader(title: title, subtitle: subtitle)
                    .padding(.bottom, Spacing.xs)
                content()
            }
            .padding(Spacing.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

/// One settings object shared by every page, so a stale copy on an unseen page
/// cannot overwrite a change made on another.
@MainActor
final class SettingsModel: ObservableObject {
    private let persistChanges: Bool
    @Published var selectedProvider: ProviderKind = .claude
    @Published var page: SettingsSection = .appearance
    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            L10n.language = settings.language
            if persistChanges { settings.save() }
            applyTheme()
        }
    }

    @Published var showRemaining: Bool {
        didSet {
            guard showRemaining != oldValue else { return }
            if persistChanges {
                displayMode.save()
                NotificationCenter.default.post(name: .quotaBarSettingsChanged, object: nil)
            }
        }
    }

    var displayMode: DisplayMode { showRemaining ? .remaining : .used }

    init(persistChanges: Bool = true) {
        self.persistChanges = persistChanges
        settings = persistChanges ? Settings.load() : .default
        showRemaining = persistChanges && DisplayMode.load() == .remaining
        L10n.language = settings.language
    }

    func applyTheme() {
        switch settings.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Always-active window material with the density used by the reference interface.
struct MaterialBackground: NSViewRepresentable {
    var sidebar = false
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        let tint = NSView()
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        view.addSubview(tint)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let dark = colorScheme == .dark
        view.subviews.last?.layer?.backgroundColor = (dark ? NSColor.black : .white)
            .withAlphaComponent(sidebar ? (dark ? 0.55 : 0.50) : (dark ? 0.35 : 0.40)).cgColor
    }
}

struct ProviderMark: View {
    let provider: ProviderKind
    var body: some View {
        Image(systemName: provider == .claude ? "sparkle" : "circle.hexagongrid")
            .accessibilityLabel(provider.displayName)
    }
}

struct StatusDot: View {
    let status: ProviderStatus
    var body: some View {
        Circle()
            .fill(status.errorMessage != nil || status.snapshot?.sourceNote != nil ? Color.orange
                  : status.snapshot == nil ? Color.secondary : Color.green)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}
