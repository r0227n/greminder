import ComposableArchitecture
import Foundation
@testable import GreminderKit
import Testing
import UserNotifications

@Suite("通知タップと認証・編集の回帰テスト")
@MainActor
struct NotificationRegressionTests {
    private let account = "user@example.com"
    private let target = ReminderTask(id: "target", remoteID: "remote-target", listID: "work", title: "通知先")
    private var snapshot: TaskSnapshot {
        TaskSnapshot(lists: [TaskList(id: "work", title: "仕事")], tasks: [target])
    }

    private func key(account: String?) -> String {
        NotificationPlanner.key(task: target, scope: NotificationPlanner.scope(account))
    }

    private func state(account: String? = nil, sampleMode: Bool = false) -> AppFeature.State {
        var state = AppFeature.State()
        state.snapshot = snapshot
        state.hasLoadedTasks = true
        state.account = account
        state.showsSampleTasks = sampleMode
        return state
    }

    private func store(_ state: AppFeature.State) -> TestStoreOf<AppFeature> {
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test("未ログイン時のサンプル通知は編集を作らずログインできる", arguments: [false, true])
    func sampleNotificationDoesNotBlockLogin(duringLoad: Bool) async {
        var state = state()
        state.isLoading = duringLoad
        let store = store(state)
        let data = ConnectedTasks(snapshot: snapshot, account: account)
        store.dependencies.taskClient.connect = { data }

        await store.send(.notificationTapped(key(account: nil)))
        #expect(store.state.editor == nil)
        #expect(store.state.pendingNotificationKey == nil)
        #expect(!store.state.showsTaskDetails)
        #expect(!store.state.canNavigateToTasks)

        if duringLoad {
            await store.send(.loaded(.success(ConnectedTasks(snapshot: snapshot))))
        }
        #expect(store.state.canSwitchAccount)
        await store.send(.connect)
        await store.receive(\.loaded)
        await store.finish()
        #expect(store.state.isSignedIn)
        #expect(store.state.canNavigateToTasks)
        #expect(store.state.editor == nil)
    }

    @Test("アカウントの通知は認証成功まで保留し、再開処理でも未ログインを迂回しない")
    func accountNotificationWaitsForLogin() async {
        let store = store(state())
        let notificationKey = key(account: account)
        let data = ConnectedTasks(snapshot: snapshot, account: account)
        store.dependencies.taskClient.connect = { data }

        await store.send(.notificationTapped(notificationKey))
        await store.send(.resumeNotificationNavigation)
        #expect(store.state.pendingNotificationKey == notificationKey)
        #expect(store.state.editor == nil)
        #expect(store.state.canSwitchAccount)

        await store.send(.connect)
        await store.receive(\.openSearchResult)
        await store.finish()
        #expect(store.state.editor?.task.id == target.id)
        #expect(store.state.selection == .list(target.listID))
        #expect(store.state.showsTaskDetails)
        #expect(store.state.pendingNotificationKey == nil)
    }

    @Test("認証中の読込失敗後も通知を保持しログインを再試行できる")
    func failedLoginRetainsNotificationForRetry() async {
        let store = store(state())
        let notificationKey = key(account: account)
        store.dependencies.taskClient.connect = { throw AppFailure("offline") }
        await store.send(.notificationTapped(notificationKey))
        await store.send(.connect)
        await store.receive(\.loaded)
        await store.finish()
        #expect(store.state.error == "offline")
        #expect(store.state.pendingNotificationKey == notificationKey)
        #expect(store.state.editor == nil)
        #expect(store.state.canSwitchAccount)

        let data = ConnectedTasks(snapshot: snapshot, account: account)
        store.dependencies.taskClient.connect = { data }
        await store.send(.connect)
        await store.receive(\.openSearchResult)
        await store.finish()
        #expect(store.state.editor?.task.id == target.id)
        #expect(store.state.pendingNotificationKey == nil)
        #expect(store.state.error == nil)
    }

    @Test("明示的なサンプル表示中は通知先を開ける")
    func sampleModeAllowsNavigation() async {
        let store = store(state())
        await store.send(.setSampleMode(true))
        await store.send(.notificationTapped(key(account: nil)))
        await store.receive(\.openSearchResult)
        await store.finish()
        #expect(store.state.showsTaskDetails)
        #expect(store.state.editor?.task.id == target.id)
        #expect(store.state.pendingNotificationKey == nil)
    }

    @Test("サンプル表示を終了すると保留していたサンプル通知を破棄する")
    func leavingSampleModeDiscardsPendingSampleNotification() async {
        var state = state(sampleMode: true)
        state.pendingNotificationKey = key(account: nil)
        let store = store(state)
        await store.send(.setSampleMode(false))
        await store.receive(\.resumeNotificationNavigation)
        await store.finish()
        #expect(!store.state.canNavigateToTasks)
        #expect(store.state.pendingNotificationKey == nil)
        #expect(store.state.editor == nil)
        #expect(store.state.canSwitchAccount)
    }

    @Test("不正なインライン入力を保持し、取消後に保留通知へ進む", arguments: [true, false], [true, false])
    func cancelInvalidInlineDraftResumesNotification(isNew: Bool, invalidTitle: Bool) async {
        var state = state(account: account)
        let original = ReminderTask(id: "draft", listID: "work", title: "元のタイトル")
        if !isNew { state.snapshot.tasks.append(original) }
        state.editor = TaskEditor(id: "editor", task: original, isNew: isNew)
        let store = store(state)
        let invalidText = String(repeating: "a", count: invalidTitle ? 1025 : 8193)
        await store.send(invalidTitle ? .editorTitle(invalidText) : .editorNotes(invalidText))
        await store.send(.notificationTapped(key(account: account)))
        await store.receive(\.resumeNotificationNavigation)
        #expect(store.state.editor?.task.id == original.id)
        #expect((invalidTitle ? store.state.editor?.task.title : store.state.editor?.task.notes) == invalidText)
        #expect(store.state.error != nil)
        #expect(store.state.pendingNotificationKey != nil)
        #expect(store.state.pending.isEmpty)

        // The inline editor's Escape key and the debug UI dispatch this same production action.
        await store.send(.cancelEditor)
        await store.receive(\.openSearchResult)
        await store.finish()
        #expect(store.state.editor?.task.id == target.id)
        #expect(store.state.showsTaskDetails)
        #expect(store.state.pendingNotificationKey == nil)
        #expect(store.state.pending.isEmpty)
        #expect(store.state.error == nil)
        #expect(store.state.snapshot.tasks.first { $0.id == original.id } == (isNew ? nil : original))
    }

    @Test("有効な編集中の変更を保存し、通知先を開く")
    func validDraftIsSavedWhenFollowingNotification() async {
        var state = state(account: account)
        let original = ReminderTask(id: "draft", listID: "work", title: "元のタイトル")
        state.snapshot.tasks.append(original)
        state.editor = TaskEditor(id: "editor", task: original, isNew: false)
        let saved = LockIsolated<[ReminderTask]>([])
        let store = store(state)
        store.dependencies.taskClient.save = { task, _, _ in
            saved.withValue { $0.append(task) }
            return task
        }
        await store.send(.editorTitle("変更したタイトル"))
        await store.send(.notificationTapped(key(account: account)))
        await store.receive(\.openSearchResult)
        await store.receive(\.writeFinished)
        await store.finish()
        #expect(saved.value.map(\.title) == ["変更したタイトル"])
        #expect(store.state.editor?.task.id == target.id)
        #expect(store.state.showsTaskDetails)
        #expect(store.state.pendingNotificationKey == nil)
    }

    @Test("詳細画面の不正な入力は取消Actionで破棄しない")
    func invalidDetailDraftRemainsProtected() async {
        var state = state(account: account)
        let draft = ReminderTask(id: "draft", listID: "work", title: String(repeating: "a", count: 1025))
        state.editor = TaskEditor(id: "editor", task: draft, isNew: false)
        state.showsTaskDetails = true
        let store = store(state)
        await store.send(.notificationTapped(key(account: account)))
        await store.receive(\.resumeNotificationNavigation)
        await store.send(.cancelEditor)
        await store.receive(\.processQueue)
        await store.finish()
        #expect(store.state.editor?.task == draft)
        #expect(store.state.pendingNotificationKey != nil)
        #expect(store.state.error != nil)
        #expect(store.state.pending.isEmpty)
    }

    @Test("削除済み・別アカウントの通知は誤ったタスクを開かない", arguments: [true, false])
    func missingOrDifferentAccountTargetIsRejected(deleted: Bool) async {
        var state = state(account: account)
        if deleted { state.snapshot.tasks = [] }
        let store = store(state)
        await store.send(.notificationTapped(key(account: deleted ? account : "other@example.com")))
        await store.receive(\.resumeNotificationNavigation)
        await store.finish()
        #expect(store.state.pendingNotificationKey == nil)
        #expect(store.state.editor == nil)
        #expect(!store.state.showsTaskDetails)
        #expect(store.state.error != nil)
    }

    @Test("保留通知がない取消は入力を破棄し遷移も保存もしない")
    func cancelWithoutNotificationSimplyClosesEditor() async {
        var state = state(account: account)
        state.editor = TaskEditor(id: "editor", task: target, isNew: false)
        state.error = "offline"
        state.writeFailed = true
        let store = store(state)
        await store.send(.editorTitle("保存しない変更"))
        await store.send(.cancelEditor)
        await store.finish()
        #expect(store.state.editor == nil)
        #expect(store.state.snapshot == snapshot)
        #expect(store.state.pending.isEmpty)
        #expect(!store.state.showsTaskDetails)
        #expect(store.state.error == "offline")
    }

    @Test("共通の通知生成は秒単位の日時とタスクキーを保持する", arguments: [false, true])
    func productionRequestPreservesScheduleAndRouting(manual: Bool) throws {
        let key = key(account: account)
        let date = Date(timeIntervalSince1970: 2_000_000_017)
        let notification = ScheduledTaskNotification(
            id: manual ? "greminder.manual.notification" : NotificationRouting.taskPrefix + key,
            title: target.title, listTitle: "仕事", date: date, taskKey: manual ? key : nil,
        )
        let request = notification.makeRequest()
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.dateComponents == Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date,
        ))
        #expect(!trigger.repeats)
        #expect(request.content.title == target.title)
        #expect(request.content.body == "仕事")
        #expect(request.content.sound != nil)
        #expect(NotificationRouting
            .key(request: request, actionIdentifier: UNNotificationDefaultActionIdentifier) == key)
        #expect(NotificationRouting
            .key(request: request, actionIdentifier: UNNotificationDismissActionIdentifier) == nil)
    }

    @Test("無関係な通知・空の識別子からタスクを復元しない", arguments: ["unrelated", "greminder.task."])
    func malformedNotificationDoesNotNavigate(identifier: String) {
        let content = UNMutableNotificationContent()
        content.userInfo[NotificationRouting.taskKeyField] = ""
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        #expect(NotificationRouting
            .key(request: request, actionIdentifier: UNNotificationDefaultActionIdentifier) == nil)
    }
}
