import Foundation

struct TasksAPISettings {
    static let preferenceKey = "greminder.api.usesMockAPI"
    let defaults: UserDefaults

    func load(defaultValue: Bool = false) -> Bool {
        defaults.object(forKey: Self.preferenceKey) as? Bool ?? defaultValue
    }

    func save(_ usesMockAPI: Bool) {
        defaults.set(usesMockAPI, forKey: Self.preferenceKey)
    }

    static var initialUsesMockAPI: Bool {
        #if DEBUG
            Self(defaults: .standard).load(
                defaultValue: ProcessInfo.processInfo.arguments.contains("--design-preview"),
            )
        #else
            false
        #endif
    }
}
