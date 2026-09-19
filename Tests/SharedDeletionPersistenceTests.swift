import Foundation
import GreminderShare
import Testing

@Suite("共有タスクの削除意思と確認の永続化")
struct SharedDeletionPersistenceTests {
    private var context: ShareContext {
        ShareContext(
            scope: "google:deletion@example.com", accountName: "Deletion",
            lists: [ShareList(id: "work", title: "Work")], selectedListID: "work",
            language: "en", notificationsEnabled: false,
        )
    }

    private func makeInbox() throws -> ShareInbox {
        let inbox = ShareInbox(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        try inbox.publish(context)
        return inbox
    }

    @Test("未送信だけを取り除き、送信準備中・送信中・保存済みの削除意思を再起動後も保持する")
    func retainsRequestsThatMayHaveReachedServer() throws {
        let inbox = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let queued = ShareDraft(title: "Unsent")
        let preparing = ShareDraft(title: "Effect not staged yet")
        let sending = ShareDraft(title: "Sending")
        let saved = ShareDraft(title: "Saved")
        let untouched = ShareDraft(title: "Unrelated")
        try inbox.enqueue([queued, preparing, sending, saved, untouched], context: context, listID: "work")
        try inbox.markSending(taskID: sending.taskID, title: sending.title, notes: "", due: nil)
        try inbox.markSaved(taskID: saved.taskID, remoteID: "saved-remote-id")

        try inbox.requestDeletion(
            taskIDs: [queued.taskID, preparing.taskID, sending.taskID, saved.taskID],
            inFlightTaskIDs: [preparing.taskID],
        )

        let requests = try ShareInbox(directory: inbox.directory).requests(scope: context.scope)
        #expect(requests.count == 4)
        #expect(!requests.contains { $0.draft.taskID == queued.taskID })
        let preparedRequest = try #require(requests.first { $0.draft.taskID == preparing.taskID })
        #expect(preparedRequest.phase == .sending)
        #expect(preparedRequest.deletionRequested)
        #expect(preparedRequest.remoteID == nil)
        let sendingRequest = try #require(requests.first { $0.draft.taskID == sending.taskID })
        #expect(sendingRequest.deletionRequested)
        let savedRequest = try #require(requests.first { $0.draft.taskID == saved.taskID })
        #expect(savedRequest.phase == .saved)
        #expect(savedRequest.deletionRequested)
        #expect(savedRequest.remoteID == "saved-remote-id")
        let untouchedRequest = try #require(requests.first { $0.draft.taskID == untouched.taskID })
        #expect(!untouchedRequest.deletionRequested)
    }

    @Test("削除要求後に届く送信開始と成功通知は削除意思を消さない")
    func lateStageAndReceiptKeepDeletionIntent() throws {
        let inbox = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let draft = ShareDraft(title: "Original", url: "https://example.com")
        try inbox.enqueue([draft], context: context, listID: "work")
        try inbox.requestDeletion(taskIDs: [draft.taskID], inFlightTaskIDs: [draft.taskID])

        try inbox.markSending(taskID: draft.taskID, title: "Sent title", notes: draft.taskNotes, due: nil)
        let staged = try #require(ShareInbox(directory: inbox.directory).requests(scope: context.scope).first)
        #expect(staged.phase == .sending)
        #expect(staged.deletionRequested)
        #expect(staged.draft.title == "Sent title")
        #expect(staged.draft.taskNotes == draft.taskNotes)

        try inbox.markSaved(taskID: draft.taskID, remoteID: "late-remote-id")
        let saved = try #require(ShareInbox(directory: inbox.directory).requests(scope: context.scope).first)
        #expect(saved.phase == .saved)
        #expect(saved.remoteID == "late-remote-id")
        #expect(saved.deletionRequested)
        #expect(saved.draft.title == "Sent title")
    }

    @Test("明示確認は同じアカウントのID未確定の削除記録だけを消す")
    func confirmationRechecksScopeIntentAndLateReceipt() throws {
        let inbox = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let unresolved = ShareDraft(title: "Unresolved")
        let lateReceipt = ShareDraft(title: "Receipt arrives during confirmation")
        let ordinary = ShareDraft(title: "Not deleted")
        try inbox.enqueue([unresolved, lateReceipt, ordinary], context: context, listID: "work")
        try inbox.requestDeletion(
            taskIDs: [unresolved.taskID, lateReceipt.taskID],
            inFlightTaskIDs: [unresolved.taskID, lateReceipt.taskID],
        )

        try inbox.confirmDeletion(taskID: unresolved.taskID, scope: "google:other@example.com")
        try inbox.confirmDeletion(taskID: ordinary.taskID, scope: context.scope)
        try inbox.markSaved(taskID: lateReceipt.taskID, remoteID: "now-known")
        try inbox.confirmDeletion(taskID: lateReceipt.taskID, scope: context.scope)
        #expect(try inbox.requests(scope: context.scope).count == 3)

        try inbox.confirmDeletion(taskID: unresolved.taskID, scope: context.scope)
        let remaining = try ShareInbox(directory: inbox.directory).requests(scope: context.scope)
        #expect(Set(remaining.map(\.draft.taskID)) == [lateReceipt.taskID, ordinary.taskID])
        let savedRequest = try #require(remaining.first { $0.draft.taskID == lateReceipt.taskID })
        #expect(savedRequest.remoteID == "now-known")
    }

    @Test("v1の削除フラグなし記録を読み、内容を変えない保存でもv2へ移行する")
    func migratesLegacyInboxOnNextWrite() throws {
        let inbox = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let url = inbox.directory.appendingPathComponent("inbox.json")
        let draft = ShareDraft(title: "Legacy task")
        var request = ShareRequest(scope: context.scope, listID: "work", draft: draft, createdAt: .distantPast)
        request.phase = .sending
        request.remoteID = "legacy-remote-id"
        var legacyRequest = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        legacyRequest.removeValue(forKey: "deletionRequested")
        let legacy: [String: Any] = try [
            "version": 1,
            "context": JSONSerialization.jsonObject(with: JSONEncoder().encode(context)),
            "requests": [legacyRequest],
        ]
        let original = try JSONSerialization.data(withJSONObject: legacy, options: .sortedKeys)
        try original.write(to: url)

        let restored = try #require(inbox.requests(scope: context.scope).first)
        #expect(restored == request)
        #expect(!restored.deletionRequested)
        #expect(try Data(contentsOf: url) == original)

        // No request/context change is needed to retire the old writable schema.
        try inbox.publish(context)
        let migrated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(migrated["version"] as? Int == 2)
        #expect(try ShareInbox(directory: inbox.directory).requests(scope: context.scope) == [request])
    }

    @Test("非対応形式や壊れた削除フラグは削除要求・確認で上書きしない", arguments: [true, false])
    func deletionOperationsPreserveUnreadableData(futureVersion: Bool) throws {
        let inbox = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let draft = ShareDraft(title: "Protected")
        try inbox.enqueue([draft], context: context, listID: "work")
        try inbox.requestDeletion(taskIDs: [draft.taskID], inFlightTaskIDs: [draft.taskID])
        let url = inbox.directory.appendingPathComponent("inbox.json")
        var contents = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        if futureVersion {
            contents["version"] = 3
        } else {
            var requests = try #require(contents["requests"] as? [[String: Any]])
            requests[0]["deletionRequested"] = "not a boolean"
            contents["requests"] = requests
        }
        let protected = try JSONSerialization.data(withJSONObject: contents, options: .sortedKeys)
        try protected.write(to: url)

        #expect(throws: (any Error).self) {
            try inbox.requestDeletion(taskIDs: [draft.taskID], inFlightTaskIDs: [])
        }
        #expect(try Data(contentsOf: url) == protected)
        #expect(throws: (any Error).self) {
            try inbox.confirmDeletion(taskID: draft.taskID, scope: context.scope)
        }
        #expect(try Data(contentsOf: url) == protected)
    }
}
