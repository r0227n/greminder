import Foundation
import GoogleAPIClientForREST_Tasks
@testable import GreminderKit
import Testing

@Suite("接続サービスの非同期操作の整合性")
@MainActor
struct TasksEnvironmentConcurrencyTests {
    private func client(_ server: TasksTestBlockServer) -> GoogleTasksService {
        let service = GTLRTasksService()
        server.attach(to: service)
        return GoogleTasksService(service: service)
    }

    @Test("遅れて完了した認証復元はログアウトを取り消さない")
    func restorationCannotUndoSignOut() async throws {
        let gate = AccountOperationGate()
        let demo = try client(TasksTestBlockServer())
        let remoteServer = try TasksTestBlockServer()
        let remote = client(remoteServer)
        var signOuts = 0
        let environment = TasksEnvironment(
            demo: demo,
            restoreAccount: {
                await gate.suspend()
                return TasksAccountConnection(client: remote, account: "old@example.com")
            },
            signIn: { throw AppFailure("Unexpected sign-in") },
            signOut: { signOuts += 1 },
        )
        let restoration = Task { try await environment.load() }
        await gate.waitUntilStarted()
        _ = try await environment.signOutAccount()
        gate.resume()
        await #expect(throws: CancellationError.self) { try await restoration.value }
        #expect(environment.client === demo)
        #expect(try await environment.load().account == nil)
        #expect(remoteServer.requestedQueries.isEmpty)
        #expect(signOuts == 1)
    }

    @Test("遅い初回スナップショットもログアウト後に接続を公開しない")
    func snapshotCannotUndoSignOut() async throws {
        let gate = AccountOperationGate()
        let demo = try client(TasksTestBlockServer())
        let service = GTLRTasksService()
        service.testBlock = { _, response in
            Task { @MainActor in
                await gate.suspend()
                response(GTLRTasks_TaskLists(), nil)
            }
        }
        let remote = GoogleTasksService(service: service)
        var cachedProfile: GoogleAccountProfile?
        let profile = GoogleAccountProfile(id: "old", email: "old@example.com", name: "Old")
        let environment = TasksEnvironment(
            demo: demo,
            saveGoogleAccount: { cachedProfile = $0 },
            signIn: { TasksAccountConnection(client: remote, account: profile.email, profile: profile) },
        )
        let connection = Task { try await environment.connect() }
        await gate.waitUntilStarted()
        _ = try await environment.signOutAccount()
        gate.resume()
        await #expect(throws: CancellationError.self) { try await connection.value }
        #expect(environment.client === demo)
        #expect(cachedProfile == nil)
        #expect(try await environment.load().account == nil)
    }

    @Test("キャンセル済みのAPI切替は通信先と保存済みモードを変更しない")
    func cancelledModeChangeDoesNotCommit() async throws {
        let gate = AccountOperationGate()
        let demo = try client(TasksTestBlockServer())
        let remoteServer = try TasksTestBlockServer()
        let remote = client(remoteServer)
        var savedModes: [Bool] = []
        let environment = TasksEnvironment(
            demo: demo, usesMockAPI: true, saveAPIMode: { savedModes.append($0) },
            restoreAccount: {
                await gate.suspend()
                return TasksAccountConnection(client: remote, account: "old@example.com")
            },
            signIn: { throw AppFailure("Unexpected sign-in") },
        )
        let change = Task { try await environment.setUsesMockAPI(false) }
        await gate.waitUntilStarted()
        change.cancel()
        gate.resume()
        await #expect(throws: CancellationError.self) { try await change.value }
        #expect(environment.usesMockAPI)
        #expect(environment.client === demo)
        #expect(savedModes.isEmpty)
        #expect(remoteServer.requestedQueries.isEmpty)
    }

    @Test("古いログイン結果は後から選んだモック接続を置き換えない")
    func signInCannotUndoModeChange() async throws {
        let gate = AccountOperationGate()
        let demo = try client(TasksTestBlockServer())
        let remote = try client(TasksTestBlockServer())
        let environment = TasksEnvironment(
            demo: demo,
            signIn: {
                await gate.suspend()
                return TasksAccountConnection(client: remote, account: "old@example.com")
            },
        )
        let connection = Task { try await environment.connect() }
        await gate.waitUntilStarted()
        let mocked = try await environment.setUsesMockAPI(true)
        gate.resume()
        await #expect(throws: CancellationError.self) { try await connection.value }
        #expect(environment.usesMockAPI)
        #expect(environment.client === demo)
        #expect(try await environment.load() == mocked)
    }
}

@MainActor
private final class AccountOperationGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
