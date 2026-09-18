import ComposableArchitecture
import Foundation
@testable import GreminderKit
import GreminderShare
import Testing
import UniformTypeIdentifiers

@Suite("Share Extensionの入力と永続化")
struct ShareExtensionTests {
    private var context: ShareContext {
        ShareContext(
            scope: "google:a@example.com",
            accountName: "A",
            lists: [ShareList(id: "work", title: "Work")],
            selectedListID: "work",
            language: "ja",
            notificationsEnabled: true,
        )
    }

    @Test("ページ名、選択テキスト、URLを失わず保存する")
    func preservesContent() {
        let draft = ShareDraft.received(title: "Apple", text: "選択した説明", url: URL(string: "https://www.apple.com/jp/"))
        #expect(draft.title == "Apple")
        #expect(draft.taskNotes == "選択した説明\n\nhttps://www.apple.com/jp/")
        #expect(draft.validationError == nil)
        #expect(ShareDraft.received(title: nil, text: nil, url: URL(string: "https://x.com/a/status/1"))
            .title == "x.com")
        #expect(ShareDraft.received(title: nil, text: "一行目\n二行目", url: nil).taskNotes == "一行目\n二行目")
        let longText = String(repeating: "あ", count: 1500)
        let longDraft = ShareDraft.received(title: nil, text: longText, url: nil)
        #expect(longDraft.title.count == 1024)
        #expect(longDraft.taskNotes == longText)
    }

    @Test("無効なURLとURLを含めた文字数超過を拒否する")
    func validatesWholeTask() {
        #expect(ShareDraft(title: " ").validationError != nil)
        #expect(ShareDraft(title: "Title", url: "file:///private/a").validationError != nil)
        #expect(ShareDraft(title: "Title", url: "javascript:alert(1)").validationError != nil)
        #expect(ShareDraft(title: "Title", notes: String(repeating: "a", count: 8190), url: "https://example.com")
            .validationError != nil)
        #expect(ShareDraft(title: "Title", notes: "https://example.com", url: "https://example.com")
            .taskNotes == "https://example.com")
    }

    @Test("再起動、二重確定、別アカウント、同期途中の状態を保持する")
    func durableInbox() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = ShareInbox(directory: directory)
        try inbox.publish(context)
        let drafts = [ShareDraft(title: "First", url: "https://example.com"), ShareDraft(title: "Second")]
        try inbox.enqueue(drafts + [drafts[0]], context: context, listID: "work")
        try inbox.enqueue(drafts, context: context, listID: "work")
        let restored = ShareInbox(directory: directory)
        #expect(try restored.requests(scope: context.scope).count == 2)
        #expect(try restored.requests(scope: "google:b@example.com").isEmpty)
        try restored.markSending(taskID: drafts[0].taskID, title: "Edited", notes: drafts[0].taskNotes, due: nil)
        #expect(try inbox.requests(scope: context.scope)[0].phase == .sending)
        try restored.markSaved(taskID: drafts[0].taskID, remoteID: "remote")
        #expect(try inbox.requests(scope: context.scope)[0].remoteID == "remote")
        try restored.remove(taskIDs: [drafts[0].taskID])
        #expect(try inbox.requests(scope: context.scope).map(\.draft.title) == ["Second"])
    }

    @Test("編集中のアカウント変更、削除済みリスト、無効なバッチは一件も保存しない")
    func rejectsChangedDestinationAndPartialBatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = ShareInbox(directory: directory)
        try inbox.publish(context)
        #expect(throws: (any Error).self) { try inbox.enqueue(
            [ShareDraft(title: "Good"), ShareDraft()],
            context: context,
            listID: "work",
        ) }
        #expect(throws: (any Error).self) { try inbox.enqueue(
            [ShareDraft(title: "Good")],
            context: context,
            listID: "deleted",
        ) }
        var other = context
        other.scope = "google:b@example.com"
        try inbox.publish(other)
        #expect(throws: (any Error).self) { try inbox.enqueue(
            [ShareDraft(title: "Good")],
            context: context,
            listID: "work",
        ) }
        #expect(try inbox.requests(scope: context.scope).isEmpty)
    }

    @Test("壊れた共有データを空のデータで上書きしない")
    func preservesCorruptData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("inbox.json")
        let bytes = Data("not json".utf8)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try ShareInbox(directory: directory).publish(context) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Safariの前処理からページ名と選択範囲を取得する")
    func safariItems() async throws {
        let item = NSExtensionItem()
        let value: NSDictionary = ["NSExtensionJavaScriptPreprocessingResultsKey": [
            "title": "Apple (日本)", "url": "https://www.apple.com/jp/", "selection": "iPhone",
        ]]
        item.attachments = [NSItemProvider(item: value, typeIdentifier: UTType.propertyList.identifier)]
        let drafts = try await ShareItemLoader.drafts(from: [item])
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "Apple (日本)")
        #expect(drafts[0].notes == "iPhone")
        #expect(drafts[0].url == "https://www.apple.com/jp/")
    }

    @Test("テキストのみの共有と複数URLの順序を保持する")
    func plainTextAndURLs() async throws {
        let text = NSExtensionItem()
        text.attachments = [NSItemProvider(item: "買い物\n牛乳" as NSString, typeIdentifier: UTType.plainText.identifier)]
        let links = NSExtensionItem()
        links.attachments = ["https://example.com/a", "https://example.org/b"].map {
            NSItemProvider(item: NSURL(string: $0), typeIdentifier: UTType.url.identifier)
        }
        let drafts = try await ShareItemLoader.drafts(from: [text, links])
        #expect(drafts.map(\.title) == ["買い物", "example.com", "example.org"])
        #expect(drafts[0].notes == "買い物\n牛乳")
    }
}

@Suite("共有ToDoの取り込みと保存キュー")
@MainActor
struct ShareImportTests {
    private let draft = ShareDraft(title: "Apple", url: "https://www.apple.com/jp/")

    private func initial() -> AppFeature.State {
        var state = AppFeature.State()
        state.snapshot.lists = [TaskList(id: "work", title: "Work")]
        state.account = "a@example.com"
        state.hasLoadedTasks = true
        // Hold the queue to inspect imported state without a live network call.
        state.writeFailed = true
        return state
    }

    @Test("Googleの挿入成功後にローカル保存が失敗してもremoteIDを失わない")
    func receiptFailureDoesNotRepeatInsertion() async {
        var state = initial()
        state.writeFailed = false
        let task = ReminderTask(id: draft.taskID, listID: "work", title: "Apple")
        state.snapshot.tasks = [task]
        state.pending = [PendingWrite(task: task)]
        let calls = LockIsolated(0)
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.taskClient.save = { task, _, _ in
                calls.withValue { $0 += 1 }
                var saved = task
                saved.remoteID = "server-id"
                return saved
            }
            $0.shareInbox.receipt = { _ in throw AppFailure("disk full") }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.processQueue)
        await store.receive(\.writeFinished)
        await store.receive(\.sharePersistenceFailed)
        await store.finish()
        #expect(store.state.snapshot.tasks[0].remoteID == "server-id")
        #expect(store.state.pending.isEmpty)
        await store.send(.retryWrites)
        await store.finish()
        #expect(calls.value == 1)
    }

    @Test("保存済みの共有ToDoは再挿入せず通知設定を復元する")
    func restoresSavedReceipt() async {
        var draft = draft
        draft.due = TaskDay("2026-10-01")!.date
        draft.notificationDate = draft.due
        var request = ShareRequest(scope: "google:a@example.com", listID: "work", draft: draft)
        request.phase = .saved
        request.remoteID = "server-id"
        let savedRequest = request
        var state = initial()
        state.snapshot.tasks = [ReminderTask(
            id: "server-id",
            remoteID: "server-id",
            listID: "work",
            title: "Apple",
            due: TaskDay("2026-10-01"),
        )]
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.shareInbox.requests = { _ in [savedRequest] }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.checkSharedTasks)
        await store.finish()
        #expect(store.state.pending.isEmpty)
        #expect(store.state.snapshot.tasks.count == 1)
        #expect(store.state.sharedAwaitingNotification == [draft.taskID])
        #expect(!store.state.canSwitchAccount)
        #expect(store.state.pendingNotificationEdits[draft.taskID]?.date == draft.notificationDate)
    }

    @Test("共有キューの削除に失敗したら画面のToDoも保持する")
    func failedCancellationKeepsDraft() async {
        var state = initial()
        let task = ReminderTask(id: draft.taskID, listID: "work", title: "Apple")
        state.snapshot.tasks = [task]
        state.pending = [PendingWrite(task: task)]
        state.deleteCandidate = task
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.shareInbox.remove = { _ in throw AppFailure("disk full") }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.confirmDelete)
        #expect(store.state.snapshot.tasks == [task])
        #expect(store.state.pending.count == 1)
        #expect(store.state.error != nil)
    }

    @Test("繰り返し取り込んでも一件だけで、URLと通知時刻を保存キューへ渡す")
    func importsOnce() async {
        var draft = draft
        draft.due = TaskDay("2026-10-01")!.date
        draft.notificationDate = draft.due
        let request = ShareRequest(scope: "google:a@example.com", listID: "work", draft: draft)
        let store = TestStore(initialState: initial()) { AppFeature() } withDependencies: {
            $0.shareInbox.requests = { scope in scope == request.scope ? [request] : [] }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.checkSharedTasks)
        await store.finish()
        await store.send(.checkSharedTasks)
        await store.finish()
        #expect(store.state.pending.count == 1)
        #expect(store.state.snapshot.tasks.count == 1)
        #expect(store.state.pending[0].task.notes == draft.url)
        #expect(store.state.pendingNotificationEdits[draft.taskID]?.date == draft.notificationDate)
    }

    @Test("送信途中で終了した挿入は自動で再送しない")
    func uncertainInsertWaitsForUser() async {
        var request = ShareRequest(scope: "google:a@example.com", listID: "work", draft: draft)
        request.phase = .sending
        let savedRequest = request
        var state = initial()
        state.writeFailed = false
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.shareInbox.requests = { _ in [savedRequest] }
            $0.taskClient.save = { _, _, _ in Issue.record("Must not repeat an uncertain insert")
                throw AppFailure("unexpected")
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.checkSharedTasks)
        await store.finish()
        #expect(store.state.writeFailed)
        #expect(store.state.error != nil)
        #expect(store.state.pending.count == 1)
    }

    @Test("ログアウト中と保存先リスト削除後は別の場所へ取り込まない")
    func doesNotRedirect() async {
        let request = ShareRequest(scope: "google:a@example.com", listID: "deleted", draft: draft)
        var state = initial()
        state.account = nil
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.shareInbox.requests = { _ in [request] }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.checkSharedTasks)
        #expect(store.state.pending.isEmpty)
        await store.send(.loaded(.success(ConnectedTasks(snapshot: initial().snapshot, account: "a@example.com"))))
        await store.finish()
        #expect(store.state.pending.isEmpty)
        #expect(store.state.snapshot.tasks.isEmpty)
        #expect(store.state.error != nil)
    }
}
