import Foundation
import os

enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var title: String { self == .english ? "English" : "简体中文" }
    var locale: Locale { Locale(identifier: rawValue) }

    static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? systemDefault()
    }
}

/// Explicit language bundles serve SwiftUI, AppKit, and background notification text.
enum L10n {
    private static let selected = OSAllocatedUnfairLock(initialState: AppLanguage.load())
    static var language: AppLanguage {
        get { selected.withLock { $0 } }
        set { selected.withLock { $0 = newValue } }
    }
    static var locale: Locale { language.locale }

    static let resourceBundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("QuotaBar_QuotaBar.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = resourceBundle.path(forResource: language.rawValue, ofType: "lproj")
                ?? resourceBundle.path(forResource: language.rawValue.lowercased(), ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resourceBundle }
        return bundle
    }

    static func text(_ key: String, language: AppLanguage, arguments: [CVarArg] = []) -> String {
        let english = bundle(for: .english).localizedString(forKey: key, value: key, table: nil)
        let format = bundle(for: language).localizedString(forKey: key, value: english, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: language.locale, arguments: arguments)
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, language: L10n.language, arguments: arguments)
}
