import ComposableArchitecture
import Foundation
import GoogleAPIClientForREST_Tasks
@testable import GreminderKit
import Testing

@Suite("API接続先の切替と永続化")
@MainActor
struct TasksAPIModeTests {
    private func client(_ server: TasksTestBlockServer) -> GoogleTasksService {
        let service = GTLRTasksService()
        server.attach(to: service)
        return GoogleTasksService(service: service)
    }

    @Test("Boolの両方を保存し、新しい設定インスタンスで復元する", arguments: [true, false])
    func persistsMode(enabled: Bool) throws {
        let suite = "TasksAPIModeTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TasksAPISettings(defaults: defaults)
        #expect(!settings.load())
        #expect(settings.load(defaultValue: true))
        settings.save(enabled)
        let restored = try TasksAPISettings(defaults: #require(UserDefaults(suiteName: suite)))
        #expect(restored.load(defaultValue: !enabled) == enabled)
    }

    @Test("保存済みモックモードではOAuthを呼ばずSDKのtestBlockでCRUDする")
    func mockModeUsesSDKWithoutOAuth() async throws {
        let server = try TasksTestBlockServer()
        let mock = client(server)
        var authCalls = 0
        let settings = TasksAPISettings(defaults: .inMemory)
        settings.save(true)
        let environment = TasksEnvironment(
            demo: mock, usesMockAPI: settings.load(),
            restoreAccount: { authCalls += 1
                return nil
            },
            signIn: { authCalls += 1
                throw AppFailure("OAuth should not be called")
            },
            signOut: { authCalls += 1 },
        )
        let loaded = try await environment.load()
        #expect(!loaded.snapshot.tasks.isEmpty)
        _ = try await environment.connect()
        let list = try await environment.client.addList("Mock list", appearance: ListAppearance())
        var task = try await environment.client.save(
            ReminderTask(id: "local", listID: list.id, title: "Create"),
            previousRemoteID: nil, parentRemoteID: nil,
        )
        task.title = "Update"
        task = try await environment.client.save(task, previousRemoteID: nil, parentRemoteID: nil)
        try await environment.client.delete(task)
        _ = try await environment.disconnect()
        #expect(authCalls == 0)
        for operation in ["TasklistsList", "TasksList", "TasklistsInsert", "TasksInsert", "TasksPatch", "TasksDelete"] {
            #expect(server.requestedQueries.contains { $0.contains(operation) })
        }
        #expect(!server.snapshot.tasks.contains { $0.remoteID == task.remoteID })
    }

    @Test("実接続とモックの往復で通信先を変更し、Googleの認証を保持する")
    func roundTripPreservesGoogleConnection() async throws {
        let mockServer = try TasksTestBlockServer()
        let remoteServer = try TasksTestBlockServer()
        let mock = client(mockServer)
        let remote = client(remoteServer)
        var signOutCalls = 0
        let settings = TasksAPISettings(defaults: .inMemory)
        let environment = TasksEnvironment(
            demo: mock, saveAPIMode: { settings.save($0) },
            signIn: { TasksAccountConnection(client: remote, account: "user@example.com") },
            signOut: { signOutCalls += 1 },
        )
        _ = try await environment.connect()
        let mocked = try await environment.setUsesMockAPI(true)
        #expect(mocked.account == nil)
        #expect(environment.client === mock)
        #expect(settings.load())
        let remoteRequestCount = remoteServer.requestedQueries.count
        _ = try await environment.client.addList("Mock only", appearance: ListAppearance())
        #expect(remoteServer.requestedQueries.count == remoteRequestCount)

        let connected = try await environment.setUsesMockAPI(false)
        #expect(connected.account == "user@example.com")
        #expect(environment.client === remote)
        #expect(!settings.load())
        let mockRequestCount = mockServer.requestedQueries.count
        _ = try await environment.client.addList("Remote only", appearance: ListAppearance())
        #expect(mockServer.requestedQueries.count == mockRequestCount)
        #expect(signOutCalls == 0)
        #expect(!connected.snapshot.lists.contains { $0.title == "Mock only" })
    }

    @Test("接続先の読込に失敗したら通信先と保存値を変えない", arguments: [true, false])
    func failedSwitchIsAtomic(enableMock: Bool) async throws {
        let mockServer = try TasksTestBlockServer()
        let remoteServer = try TasksTestBlockServer()
        let mock = client(mockServer)
        let remote = client(remoteServer)
        let settings = TasksAPISettings(defaults: .inMemory)
        settings.save(!enableMock)
        let connection = TasksAccountConnection(client: remote, account: "user@example.com")
        let environment = TasksEnvironment(
            demo: mock, usesMockAPI: !enableMock, saveAPIMode: { settings.save($0) },
            restoreAccount: { connection }, signIn: { connection },
        )
        _ = try await environment.load()
        (enableMock ? mockServer : remoteServer).failNextRequest = AppFailure("offline")
        await #expect(throws: AppFailure("offline")) {
            try await environment.setUsesMockAPI(enableMock)
        }
        #expect(environment.usesMockAPI == !enableMock)
        #expect(settings.load() == !enableMock)
        #expect(environment.client === (enableMock ? remote : mock))
    }

    @Test("未認証の実APIモードはモックのリクエストにフォールバックしない")
    func signedOutLiveModeDoesNotUseMock() async throws {
        let server = try TasksTestBlockServer()
        let environment = TasksEnvironment(
            demo: client(server), usesMockAPI: true,
            signIn: { throw AppFailure("not signed in") },
        )
        let disconnected = try await environment.setUsesMockAPI(false)
        #expect(disconnected.account == nil)
        #expect(disconnected.snapshot == TaskSnapshot())
        _ = try await environment.load()
        #expect(server.requestedQueries.isEmpty)
    }

    private func store(_ state: AppFeature.State = AppFeature.State()) -> TestStoreOf<AppFeature> {
        let store = TestStore(initialState: state) { AppFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test("切替成功後に表示と通知の状態を新しい接続先へ切り替える", arguments: [true, false])
    func reducerSwitchesAfterSuccess(enabled: Bool) async {
        var state = AppFeature.State()
        state.usesMockAPI = !enabled
        state.showsSampleTasks = !enabled
        state.pendingNotificationKey = "old-account-notification"
        state.selection = .list("old-list")
        state.search = "old search"
        state.collapsed = ["old-task"]
        let store = store(state)
        let destination = ConnectedTasks(snapshot: .sample(), account: enabled ? nil : "user@example.com")
        store.dependencies.taskClient.setUsesMockAPI = { _ in destination }
        await store.send(.setUsesMockAPI(enabled))
        #expect(store.state.isLoading)
        #expect(store.state.usesMockAPI == !enabled)
        await store.receive(\.apiModeChanged)
        await store.receive(\.loaded)
        await store.finish()
        #expect(store.state.usesMockAPI == enabled)
        #expect(store.state.showsSampleTasks == enabled)
        #expect(store.state.account == destination.account)
        #expect(store.state.snapshot == destination.snapshot)
        #expect(store.state.pendingNotificationKey == nil)
        #expect(store.state.selection == .today)
        #expect(store.state.search.isEmpty)
        #expect(store.state.collapsed.isEmpty)
        #expect(!store.state.isLoading)
    }

    @Test("切替失敗時は表示を維持し再試行できる")
    func reducerRetainsModeOnFailure() async {
        var state = AppFeature.State()
        state.snapshot = .sample()
        let store = store(state)
        store.dependencies.taskClient.setUsesMockAPI = { _ in throw AppFailure("offline") }
        await store.send(.setUsesMockAPI(true))
        await store.receive(\.apiModeChanged)
        await store.finish()
        #expect(!store.state.usesMockAPI)
        #expect(store.state.snapshot == state.snapshot)
        #expect(store.state.error == "offline")
        #expect(store.state.canSwitchAccount)
    }

    @Test("編集中・保存中・読込中・音声入力中は接続先を変更しない", arguments: ["edit", "write", "load", "voice"])
    func blocksSwitchWhileBusy(reason: String) async {
        var state = AppFeature.State()
        let task = ReminderTask(id: "draft", listID: "work", title: "Draft")
        switch reason {
        case "edit": state.editor = TaskEditor(id: "editor", task: task, isNew: true)
        case "write": state.pending = [PendingWrite(task: task)]
        case "load": state.isLoading = true
        default: state.showsVoice = true
        }
        let calls = LockIsolated(0)
        let store = store(state)
        store.dependencies.taskClient.setUsesMockAPI = { _ in
            calls.withValue { $0 += 1 }
            return ConnectedTasks(snapshot: TaskSnapshot())
        }
        await store.send(.setUsesMockAPI(true))
        await store.finish()
        #expect(calls.value == 0)
        #expect(store.state == state)
    }
}
