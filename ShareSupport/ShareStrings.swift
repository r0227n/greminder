import Foundation

public struct ShareStrings: Sendable {
    public var language: String
    public init(language: String = Locale.preferredLanguages.first ?? "en") { self.language = language }
    public func callAsFunction(_ key: String) -> String {
        let code = language.hasPrefix("ja") ? "ja" : "en"
        let bundle = Bundle.module.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
