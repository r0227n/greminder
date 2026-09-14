import ComposableArchitecture
import Foundation

// Display language is independent from Whisper's recognition language.
enum DisplayLanguage: String, CaseIterable, Sendable {
    case system, japanese = "ja", english = "en"

    var label: String {
        switch self {
        case .system: L10n.tr("システム設定に従う")
        case .japanese: "日本語"
        case .english: "English"
        }
    }
}

enum L10n {
    static let preferenceKey = "displayLanguage_v2"
    static var initialLanguage: DisplayLanguage {
        @Dependency(\.defaultAppStorage) var defaults
        if defaults.object(forKey: preferenceKey) == nil,
           let legacy = defaults.string(forKey: "displayLanguage.v1"), DisplayLanguage(rawValue: legacy) != nil
        {
            defaults.set(legacy, forKey: preferenceKey)
        }
        return .system
    }

    static var language: DisplayLanguage {
        @SharedReader(.appStorage(preferenceKey)) var language = initialLanguage
        return language
    }

    static func identifier(for language: DisplayLanguage) -> String {
        guard language == .system else { return language.rawValue }
        return Locale.preferredLanguages.first(where: { $0.hasPrefix("ja") || $0.hasPrefix("en") })?
            .hasPrefix("ja") == true ? "ja" : "en"
    }

    static var locale: Locale { Locale(identifier: identifier(for: language)) }

    static func tr(_ key: String, _ arguments: String...) -> String {
        translate(key, arguments: arguments, language: language)
    }

    static func translate(_ key: String, arguments: [String] = [], language: DisplayLanguage) -> String {
        let identifier = identifier(for: language)
        let bundle = Bundle.module.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: identifier), arguments: arguments)
    }
}
