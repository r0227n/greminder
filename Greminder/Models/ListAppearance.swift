import Foundation

struct ListAppearance: Codable, Equatable, Sendable {
    var symbol = "list.bullet"
    var tint = "blue"

    static let symbols = ["list.bullet", "briefcase.fill", "person.fill", "cart.fill", "house.fill", "book.fill",
                          "heart.fill", "star.fill", "airplane", "gift.fill", "graduationcap.fill", "figure.run"]
    static let colors = [
        "blue",
        "red",
        "orange",
        "yellow",
        "green",
        "mint",
        "cyan",
        "purple",
        "pink",
        "brown",
        "gray",
        "indigo",
    ]

    static func symbolLabel(_ symbol: String) -> String {
        switch symbol {
        case "briefcase.fill": L10n.tr("仕事")
        case "person.fill": L10n.tr("人")
        case "cart.fill": L10n.tr("買い物")
        case "house.fill": L10n.tr("家")
        case "book.fill": L10n.tr("本")
        case "heart.fill": L10n.tr("ハート")
        case "star.fill": L10n.tr("星")
        case "airplane": L10n.tr("旅行")
        case "gift.fill": L10n.tr("ギフト")
        case "graduationcap.fill": L10n.tr("学習")
        case "figure.run": L10n.tr("運動")
        default: L10n.tr("リスト")
        }
    }

    static func colorLabel(_ color: String) -> String {
        switch color {
        case "red": L10n.tr("赤")
        case "orange": L10n.tr("オレンジ")
        case "yellow": L10n.tr("黄")
        case "green": L10n.tr("緑")
        case "mint": L10n.tr("ミント")
        case "cyan": L10n.tr("水色")
        case "purple": L10n.tr("紫")
        case "pink": L10n.tr("ピンク")
        case "brown": L10n.tr("茶")
        case "gray": L10n.tr("グレー")
        case "indigo": L10n.tr("藍色")
        default: L10n.tr("青")
        }
    }

    var validated: Self {
        Self(
            symbol: Self.symbols.contains(symbol) ? symbol : "list.bullet",
            tint: Self.colors.contains(tint) ? tint : "blue",
        )
    }

    static func suggested(for title: String, index: Int) -> Self {
        if title.contains("仕事") || title.localizedCaseInsensitiveContains("work") {
            return Self(symbol: "briefcase.fill", tint: "blue")
        }
        if title.contains("買い物") || title.localizedCaseInsensitiveContains("shopping") {
            return Self(symbol: "cart.fill", tint: "green")
        }
        if title.contains("プライベート") || title.localizedCaseInsensitiveContains("personal") {
            return Self(symbol: "person.fill", tint: "red")
        }
        return Self(tint: ["blue", "red", "green"][index % 3])
    }
}

/// Google Tasks has no appearance fields. Keep these separate from remote task data.
@MainActor
final class ListAppearanceStore {
    private let defaults: UserDefaults?
    private var values: [String: [String: ListAppearance]] = [:]
    private static let key = "listAppearances.v1"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    func appearance(account: String, listID: String) -> ListAppearance? {
        currentValues[account]?[listID]?.validated
    }

    func resolve(account: String, listID: String, suggested: ListAppearance) -> ListAppearance {
        if let stored = appearance(account: account, listID: listID) { return stored }
        save(suggested, account: account, listID: listID)
        return suggested.validated
    }

    func save(_ appearance: ListAppearance, account: String, listID: String) {
        // Read the persisted source before merging, so another store/window's writes survive.
        values = currentValues
        values[account, default: [:]][listID] = appearance.validated
        if let data = try? JSONEncoder().encode(values) { defaults?.set(data, forKey: Self.key) }
    }

    private var currentValues: [String: [String: ListAppearance]] {
        guard let defaults else { return values }
        return defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: [String: ListAppearance]].self, from: $0) } ?? [:]
    }
}
