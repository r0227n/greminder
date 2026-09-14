import ComposableArchitecture
import Foundation
import GoogleAPIClientForREST_Tasks
import GoogleSignIn
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

struct ConnectedTasks: Equatable, Sendable {
    var snapshot: TaskSnapshot
    var account: String?
}

struct TaskClient: Sendable {
    var load: @Sendable () async throws -> ConnectedTasks
    var save: @Sendable (ReminderTask, String?, String?) async throws -> ReminderTask
    var delete: @Sendable (ReminderTask) async throws -> Void
    var addList: @Sendable (String, ListAppearance) async throws -> TaskList
    var connect: @Sendable () async throws -> ConnectedTasks
    var disconnect: @Sendable () async throws -> ConnectedTasks
}

extension TaskClient: DependencyKey {
    static let liveValue = Self(
        load: { try await TasksEnvironment.shared.load() },
        save: { try await TasksEnvironment.shared.client.save($0, previousRemoteID: $1, parentRemoteID: $2) },
        delete: { try await TasksEnvironment.shared.client.delete($0) },
        addList: { try await TasksEnvironment.shared.client.addList($0, appearance: $1) },
        connect: { try await TasksEnvironment.shared.connect() },
        disconnect: { try await TasksEnvironment.shared.disconnect() },
    )
    static let testValue = Self(
        load: { throw AppFailure("load dependency must be supplied") },
        save: { _, _, _ in throw AppFailure("save dependency must be supplied") },
        delete: { _ in throw AppFailure("delete dependency must be supplied") },
        addList: { _, _ in throw AppFailure("addList dependency must be supplied") },
        connect: { throw AppFailure("connect dependency must be supplied") },
        disconnect: { throw AppFailure("disconnect dependency must be supplied") },
    )
}

extension DependencyValues {
    var taskClient: TaskClient {
        get { self[TaskClient.self] }
        set { self[TaskClient.self] = newValue }
    }
}

/// An account is published only after its first snapshot has loaded successfully.
/// OAuth presentation and session restoration are injected so failed switches can be tested.
@MainActor
struct TasksAccountConnection {
    var client: GoogleTasksService
    var account: String?
}

@MainActor
final class TasksEnvironment {
    static let shared = TasksEnvironment()
    private(set) var client: GoogleTasksService
    private let demo: GoogleTasksService
    private let initializationError: Error?
    private let restoreAccount: @MainActor () async throws -> TasksAccountConnection?
    private let signIn: @MainActor () async throws -> TasksAccountConnection
    private let signOut: @MainActor () -> Void
    private var account: String?
    private var didRestore = false

    static var isConfigured: Bool {
        let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? ""
        return id.hasSuffix(".apps.googleusercontent.com") && !id.contains("$(")
    }

    init(
        demo: GoogleTasksService,
        initializationError: Error? = nil,
        restoreAccount: @escaping @MainActor () async throws -> TasksAccountConnection? = { nil },
        signIn: @escaping @MainActor () async throws -> TasksAccountConnection,
        signOut: @escaping @MainActor () -> Void = {},
    ) {
        self.demo = demo
        client = demo
        self.initializationError = initializationError
        self.restoreAccount = restoreAccount
        self.signIn = signIn
        self.signOut = signOut
    }

    private convenience init() {
        let service = GTLRTasksService()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let isPreview = ProcessInfo.processInfo.arguments.contains("--design-preview")
        let appearances = ListAppearanceStore(defaults: isPreview ? nil : .standard)
        let url = isPreview ? nil : base.appendingPathComponent("Greminder/sample-tasks.json")
        var initializationError: Error?
        do {
            let server = try TasksTestBlockServer(fileURL: url)
            server.attach(to: service)
        } catch { initializationError = error }
        self.init(
            demo: GoogleTasksService(service: service, appearances: appearances),
            initializationError: initializationError,
            restoreAccount: {
                guard !isPreview, Self.isConfigured, GIDSignIn.sharedInstance.hasPreviousSignIn() else { return nil }
                let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                return try Self.connection(for: user, appearances: appearances)
            },
            signIn: {
                try await Self.presentSignIn(appearances: appearances)
            },
            signOut: { GIDSignIn.sharedInstance.signOut() },
        )
    }

    func load() async throws -> ConnectedTasks {
        if !didRestore, let restored = try await restoreAccount() {
            return try await activate(restored)
        }
        let snapshot = try await loadSnapshot(from: client)
        didRestore = true
        return ConnectedTasks(snapshot: snapshot, account: account)
    }

    func connect() async throws -> ConnectedTasks {
        try await activate(signIn())
    }

    func disconnect() async throws -> ConnectedTasks {
        // Prepare the destination before invalidating the current account's credentials.
        let snapshot = try await loadSnapshot(from: demo)
        signOut()
        client = demo
        account = nil
        didRestore = true
        return ConnectedTasks(snapshot: snapshot, account: nil)
    }

    private func activate(_ connection: TasksAccountConnection) async throws -> ConnectedTasks {
        let snapshot = try await loadSnapshot(from: connection.client)
        client = connection.client
        account = connection.account
        didRestore = true
        return ConnectedTasks(snapshot: snapshot, account: account)
    }

    private func loadSnapshot(from client: GoogleTasksService) async throws -> TaskSnapshot {
        if client === demo, let initializationError { throw AppFailure(L10n.tr(
            "サンプルデータを読み込めません: %@",
            String(describing: initializationError.localizedDescription),
        )) }
        return try await client.load()
    }

    private static func presentSignIn(appearances: ListAppearanceStore) async throws -> TasksAccountConnection {
        guard isConfigured else { throw AppFailure(L10n.tr("Google連携の初期設定が必要です。docs/google-setup.mdをご確認ください。")) }
        let scopes = [kGTLRAuthScopeTasks]
        #if os(macOS)
            guard let window = NSApp.keyWindow ?? NSApp.windows.first
            else { throw AppFailure(L10n.tr("サインイン画面を開けませんでした。")) }
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: window,
                hint: nil,
                additionalScopes: scopes,
            )
        #else
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            else { throw AppFailure(L10n.tr("サインイン画面を開けませんでした。")) }
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: scopes,
            )
        #endif
        return try connection(for: result.user, appearances: appearances)
    }

    private static func connection(
        for user: GIDGoogleUser,
        appearances: ListAppearanceStore,
    ) throws -> TasksAccountConnection {
        guard user.grantedScopes?.contains(kGTLRAuthScopeTasks) == true else {
            throw AppFailure(L10n.tr("Google Tasksへのアクセスが許可されていません。もう一度接続してください。"))
        }
        let service = GTLRTasksService()
        service.authorizer = user.fetcherAuthorizer
        let client = GoogleTasksService(
            service: service,
            appearances: appearances,
            accountKey: "google:" + (user.userID ?? user.profile?.email ?? "unknown"),
        ) // No testBlock in the live account.
        return TasksAccountConnection(client: client, account: user.profile?.email ?? L10n.tr("Googleアカウント"))
    }
}
