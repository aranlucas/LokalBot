import Foundation

/// Interface language only. Speech recognition and generated notes keep their
/// own preferences; changing the interface never changes stored user content.
enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Native names keep the language picker recognizable in either language.
    var displayName: String {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    func localizationIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        for language in preferredLanguages {
            let code = language.replacingOccurrences(of: "_", with: "-").lowercased()
            if code == "zh" || code.hasPrefix("zh-") { return "zh-Hans" }
            if code == "en" || code.hasPrefix("en-") { return "en" }
        }
        return "en"
    }

    var locale: Locale { Locale(identifier: localizationIdentifier()) }

    /// Native text-field bridges receive the locale from their SwiftUI parent.
    static func matching(_ locale: Locale) -> Self {
        let identifier = Self.system.localizationIdentifier(preferredLanguages: [locale.identifier])
        return Self(rawValue: identifier) ?? .english
    }

    /// AppKit menus and settings search do not read SwiftUI's locale. Resolve
    /// their app-owned labels explicitly without changing AppleLanguages or
    /// replacing Bundle.main (which would affect other frameworks).
    func localized(_ key: String, bundle: Bundle = .main) -> String {
        guard let path = bundle.path(forResource: localizationIdentifier(), ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else { return key }
        return localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }
}
