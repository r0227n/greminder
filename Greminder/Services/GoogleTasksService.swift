import Foundation
import GoogleAPIClientForREST_Tasks

/// The only Tasks transport. Both the live account and the demo use executeQuery.
@MainActor
final class GoogleTasksService {
    private let service: GTLRTasksService
    private let appearances: ListAppearanceStore
    private let accountKey: String

    init(
        service: GTLRTasksService,
        appearances: ListAppearanceStore? = nil,
        accountKey: String = "sample",
    ) {
        self.appearances = appearances ?? ListAppearanceStore()
        self.accountKey = accountKey
        self.service = service
        service.callbackQueue = .main
        service.shouldFetchNextPages = false // Explicit pagination is also exercised by testBlock.
        service.isRetryEnabled = false // Never silently replay task creation after a timeout.
    }

    func load() async throws -> TaskSnapshot {
        var snapshot = TaskSnapshot()
        var page: String?
        repeat {
            let query = GTLRTasksQuery_TasklistsList.query()
            query.maxResults = 100
            query.pageToken = page
            let result: GTLRTasks_TaskLists = try await execute(query)
            let offset = snapshot.lists.count
            snapshot.lists += (result.items ?? []).enumerated().compactMap { index, item in
                guard let id = item.identifier else { return nil }
                let style = appearances.resolve(
                    account: accountKey,
                    listID: id,
                    suggested: .suggested(for: item.title ?? "", index: offset + index),
                )
                return TaskList(id: id, title: item.title ?? L10n.tr("名称未設定"), symbol: style.symbol, tint: style.tint)
            }
            page = result.nextPageToken
        } while page != nil
        for list in snapshot.lists {
            page = nil
            repeat {
                let query = GTLRTasksQuery_TasksList.query(withTasklist: list.id)
                query.maxResults = 100
                query.showCompleted = true
                query.showHidden = true
                query.pageToken = page
                let result: GTLRTasks_Tasks = try await execute(query)
                snapshot.tasks += (result.items ?? []).compactMap { Self.model($0, listID: list.id) }
                page = result.nextPageToken
            } while page != nil
        }
        return snapshot
    }

    func save(_ task: ReminderTask, previousRemoteID: String?, parentRemoteID: String?) async throws -> ReminderTask {
        let object = Self.object(task)
        let query: GTLRQuery
        if let remoteID = task.remoteID {
            let patch = GTLRTasksQuery_TasksPatch.query(withObject: object, tasklist: task.listID, task: remoteID)
            // nil omits a PATCH key; JSON null explicitly clears the date.
            if task.due == nil { object.setJSONValue(NSNull(), forKey: "due") }
            if let etag = task.etag { patch.additionalHTTPHeaders = ["If-Match": etag] }
            query = patch
        } else {
            guard task.parentID == nil || parentRemoteID != nil else {
                throw AppFailure(L10n.tr("親タスクの保存が完了していません。再試行してください。"))
            }
            let insert = GTLRTasksQuery_TasksInsert.query(withObject: object, tasklist: task.listID)
            insert.previous = previousRemoteID
            insert.parent = parentRemoteID
            query = insert
        }
        let result: GTLRTasks_Task = try await execute(query)
        guard var saved = Self.model(result, listID: task.listID) else {
            throw AppFailure(L10n.tr("GoogleからタスクIDが返されませんでした。再読み込みして確認してください。"))
        }
        saved.id = task.id // Preserve SwiftUI identity and queued references after an insert.
        saved.parentID = task.parentID
        return saved
    }

    func delete(_ task: ReminderTask) async throws {
        guard let remoteID = task.remoteID else { return }
        let query = GTLRTasksQuery_TasksDelete.query(withTasklist: task.listID, task: remoteID)
        if let etag = task.etag { query.additionalHTTPHeaders = ["If-Match": etag] }
        do {
            _ = try await executeObject(query)
        } catch {
            // The remote delete may have succeeded before local inbox cleanup failed.
            // Retrying an already absent task must still allow that cleanup to finish.
            let response = error as NSError
            guard response.code == 404,
                  [kGTLRErrorObjectDomain, kGTMSessionFetcherStatusDomain].contains(response.domain)
            else { throw error }
        }
    }

    func addList(_ title: String, appearance: ListAppearance = ListAppearance()) async throws -> TaskList {
        let object = GTLRTasks_TaskList()
        object.title = title
        let result: GTLRTasks_TaskList = try await execute(GTLRTasksQuery_TasklistsInsert.query(withObject: object))
        guard let id = result.identifier else { throw AppFailure(L10n.tr("リストIDを取得できませんでした。")) }
        let style = appearance.validated
        appearances.save(style, account: accountKey, listID: id)
        return TaskList(id: id, title: result.title ?? title, symbol: style.symbol, tint: style.tint)
    }

    private func execute<T: GTLRObject>(_ query: GTLRQuery) async throws -> T {
        guard let result = try await executeObject(query) as? T else {
            throw AppFailure(L10n.tr("Google Tasksから予期しない形式の応答がありました。"))
        }
        return result
    }

    private func executeObject(_ query: GTLRQuery) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            service.executeQuery(query) { _, object, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: object) }
            }
        }
    }

    static func model(_ object: GTLRTasks_Task, listID: String) -> ReminderTask? {
        guard let id = object.identifier, object.deleted?.boolValue != true else { return nil }
        return ReminderTask(
            id: id,
            remoteID: id,
            listID: listID,
            title: object.title ?? "",
            notes: object.notes ?? "",
            due: object.due.flatMap { TaskDay(String($0.prefix(10))) },
            isCompleted: object.status == "completed",
            parentID: object.parent,
            position: object.position ?? "",
            etag: object.eTag,
        )
    }

    static func object(_ task: ReminderTask) -> GTLRTasks_Task {
        let value = GTLRTasks_Task()
        value.title = task.title
        value.notes = task.notes
        value.status = task.isCompleted ? "completed" : "needsAction"
        value.due = task.due?.apiValue
        return value
    }
}
