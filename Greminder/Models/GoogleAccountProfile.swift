import Foundation

/// Display metadata only. OAuth credentials remain managed by Google Sign-In's keychain.
struct GoogleAccountProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var email: String
    var name: String
    var imageURL: URL?

    var displayName: String { name.isEmpty ? email : name }
}

struct GoogleAccountProfileCache {
    private static let key = "greminder.google.profile"
    let defaults: UserDefaults

    func load() -> GoogleAccountProfile? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(GoogleAccountProfile.self, from: $0) }
    }

    func save(_ profile: GoogleAccountProfile?) {
        guard let profile else { defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(try? JSONEncoder().encode(profile), forKey: Self.key)
    }
}
