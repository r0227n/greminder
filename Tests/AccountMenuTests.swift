import ComposableArchitecture
import Foundation
import GoogleAPIClientForREST_Tasks
import GoogleSignIn
@testable import GreminderKit
import Testing

@Suite("アカウントメニュー")
@MainActor
struct AccountMenuTests {
    private let profile = GoogleAccountProfile(
        id: "account", email: "user@example.com", name: "Test User",
        imageURL: URL(string: "https://example.com/avatar.png"),
    )

    private func client(_ server: TasksTestBlockServer) -> GoogleTasksService {
        let service = GTLRTasksService()
        server.attach(to: service)
        return GoogleTasksService(service: service)
    }

    @Test("プロフィールを復元し、ログアウトでキャッシュを消す")
    func profileCache() throws {
        let suite = "AccountMenuTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = GoogleAccountProfileCache(defaults: defaults)
        cache.save(profile)
        #expect(GoogleAccountProfileCache(defaults: defaults).load() == profile)
        cache.save(nil)
        #expect(cache.load() == nil)
    }

    @Test("モック中もログインとログアウトができ、タスクの接続先は変えない")
    func accountManagementWhileMocking() async throws {
        let mockServer = try TasksTestBlockServer()
        let remoteServer = try TasksTestBlockServer()
        let mock = client(mockServer)
        let remote = client(remoteServer)
        var saved: GoogleAccountProfile?
        var signIns = 0
        var signOuts = 0
        let environment = TasksEnvironment(
            demo: mock, usesMockAPI: true, saveGoogleAccount: { saved = $0 },
            restoreAccount: { throw AppFailure("expired credentials") },
            signIn: {
                signIns += 1
                return TasksAccountConnection(client: remote, account: profile.email, profile: profile)
            },
            signOut: { signOuts += 1 },
        )
        await #expect(throws: AppFailure("expired credentials")) {
            try await environment.setUsesMockAPI(false)
        }
        let signedIn = try await environment.signInAccount()
        #expect(signedIn.googleAccount == profile)
        #expect(signedIn.account == nil)
        #expect(environment.client === mock)
        #expect(saved == profile)
        #expect(remoteServer.requestedQueries.isEmpty)
        let reloaded = try await environment.load()
        #expect(reloaded.googleAccount == profile)
        let signedOut = try await environment.signOutAccount()
        #expect(signedOut.googleAccount == nil)
        #expect(signedOut.snapshot == signedIn.snapshot)
        #expect(environment.usesMockAPI)
        #expect(environment.client === mock)
        #expect(saved == nil)
        #expect(signIns == 1 && signOuts == 1)
    }

    @Test("実APIのプロフィールを公開し、モックとの往復でも保持する")
    func profileAcrossModeChanges() async throws {
        let mock = try client(TasksTestBlockServer())
        let remote = try client(TasksTestBlockServer())
        let environment = TasksEnvironment(
            demo: mock,
            signIn: { TasksAccountConnection(client: remote, account: profile.email, profile: profile) },
        )
        let signedIn = try await environment.signInAccount()
        #expect(signedIn.account == profile.email && signedIn.googleAccount == profile)
        let mocked = try await environment.setUsesMockAPI(true)
        #expect(mocked.googleAccount == profile)
        let live = try await environment.setUsesMockAPI(false)
        #expect(live.googleAccount == profile)
        let signedOut = try await environment.signOutAccount()
        #expect(signedOut.account == nil && signedOut.googleAccount == nil)
    }

    @Test("ログイン成功とログアウトをアカウント一覧へ反映する")
    func reducerPublishesAccount() async {
        var state = AppFeature.State()
        state.usesMockAPI = true
        state.showsSampleTasks = true
        let store = TestStore(initialState: state) { AppFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        store.dependencies.taskClient.signInAccount = {
            ConnectedTasks(snapshot: .sample(), googleAccount: profile)
        }
        store.dependencies.taskClient.signOutAccount = { ConnectedTasks(snapshot: .sample()) }
        await store.send(.signInAccount)
        await store.receive(\.loaded)
        #expect(store.state.signedInAccounts == [profile])
        #expect(store.state.usesMockAPI)
        await store.send(.signOutAccount)
        await store.receive(\.loaded)
        #expect(store.state.signedInAccounts.isEmpty)
        await store.finish()
    }

    @Test("認証キャンセルと失敗では既存のプロフィールを保持する", arguments: [true, false])
    func failedSignIn(cancelled: Bool) async {
        var state = AppFeature.State()
        state.googleAccount = profile
        let store = TestStore(initialState: state) { AppFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        store.dependencies.taskClient.signInAccount = {
            if cancelled {
                throw NSError(domain: kGIDSignInErrorDomain, code: GIDSignInError.canceled.rawValue)
            }
            throw AppFailure("offline")
        }
        await store.send(.signInAccount)
        if cancelled { await store.receive(\.signInCancelled) }
        else { await store.receive(\.loaded) }
        #expect(store.state.googleAccount == profile)
        #expect(store.state.error == (cancelled ? nil : "offline"))
        #expect(!store.state.isLoading)
        await store.finish()
    }

    @Test("編集・保存中にはアカウント操作を開始しない", arguments: [true, false])
    func blocksAccountChanges(editing: Bool) async {
        var state = AppFeature.State()
        let task = ReminderTask(id: "draft", listID: "list", title: "Draft")
        if editing { state.editor = TaskEditor(id: "editor", task: task, isNew: true) }
        else { state.pending = [PendingWrite(task: task)] }
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.signInAccount)
        await store.send(.signOutAccount)
        await store.finish()
    }

    @Test("通知タップはアカウントモーダルを閉じてからタスクを開く")
    func notificationDismissesMenu() async throws {
        var state = AppFeature.State()
        state.snapshot = .sample()
        state.showsSampleTasks = true
        state.accountMenuSource = "tasks"
        let task = try #require(state.snapshot.tasks.first)
        let key = NotificationPlanner.key(task: task, scope: NotificationPlanner.scope(nil))
        let store = TestStore(initialState: state) { AppFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        store.dependencies.uuid = .incrementing
        await store.send(.notificationTapped(key))
        #expect(store.state.accountMenuSource == nil)
        #expect(store.state.waitsForNotificationDismissal)
        #expect(store.state.editor == nil)
        await store.send(.notificationPresentationDismissed)
        await store.receive(\.resumeNotificationNavigation)
        await store.receive(\.openSearchResult)
        #expect(store.state.editor?.task.id == task.id)
        await store.finish()
    }
}
