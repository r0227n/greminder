import Foundation
import GoogleAPIClientForREST_Tasks

/// An in-process Tasks server behind the SDK's testBlock, not a replacement client.
/// The test query object, parameters, body and async callback are the production ones.
@MainActor
final class TasksTestBlockServer {
    var snapshot: TaskSnapshot
    var requestedQueries: [String] = []
    var failNextRequest: AppFailure?
    let fileURL: URL?
    let pageSize: Int

    init(snapshot: TaskSnapshot = .sample(), fileURL: URL? = nil, pageSize: Int = 100) throws {
        self.fileURL = fileURL
        self.pageSize = max(1, pageSize)
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            self.snapshot = try JSONDecoder().decode(TaskSnapshot.self, from: Data(contentsOf: fileURL))
        } else { self.snapshot = snapshot }
        for index in self.snapshot.tasks.indices where self.snapshot.tasks[index].etag == nil {
            self.snapshot.tasks[index].etag = UUID().uuidString
        }
    }

    func attach(to service: GTLRTasksService) {
        service.testBlock = { [self] ticket, response in
            Task { @MainActor in
                do { try response(self.respond(to: ticket.originalQuery), nil) }
                catch { response(nil, error as NSError) }
            }
        }
    }

    func respond(to query: GTLRQueryProtocol?) throws -> GTLRObject? {
        guard let query else { throw AppFailure(L10n.tr("クエリがありません。")) }
        requestedQueries.append(String(describing: type(of: query)))
        if let failure = failNextRequest { failNextRequest = nil
            throw failure
        }
        if let q = query as? GTLRTasksQuery_TasklistsList {
            let result = GTLRTasks_TaskLists()
            let offset = Int(q.pageToken ?? "0") ?? 0
            result.items = snapshot.lists.dropFirst(offset).prefix(pageSize).map { list in
                let value = GTLRTasks_TaskList()
                value.identifier = list.id
                value.title = list.title
                return value
            }
            result.nextPageToken = offset + pageSize < snapshot.lists.count ? "\(offset + pageSize)" : nil
            return result
        }
        if let q = query as? GTLRTasksQuery_TasksList {
            let result = GTLRTasks_Tasks()
            let values = snapshot.tasks.filter { $0.listID == q.tasklist && (q.showCompleted || !$0.isCompleted) }
            let offset = Int(q.pageToken ?? "0") ?? 0
            result.items = values.dropFirst(offset).prefix(pageSize).map(apiObject)
            result.nextPageToken = offset + pageSize < values.count ? "\(offset + pageSize)" : nil
            return result
        }
        if let q = query as? GTLRTasksQuery_TasksInsert, let body = q.bodyObject as? GTLRTasks_Task,
           let listID = q.tasklist
        {
            guard snapshot.lists.contains(where: { $0.id == listID }) else { throw AppFailure(L10n.tr("リストが見つかりません。")) }
            if let parent = q.parent {
                guard snapshot.tasks.contains(where: { $0.id == parent && $0.listID == listID && $0.parentID == nil })
                else { throw responseError(400, "Invalid parent") }
            }
            if let previous = q.previous {
                guard snapshot.tasks.contains(where: {
                    $0.id == previous && $0.listID == listID && $0.parentID == q.parent
                }) else { throw responseError(400, "Invalid previous sibling") }
            }
            let id = UUID().uuidString
            body.identifier = id
            body.parent = q.parent
            body.eTag = UUID().uuidString
            guard let item = GoogleTasksService.model(body, listID: listID)
            else { throw AppFailure(L10n.tr("タスクの形式が不正です。")) }
            var updated = snapshot
            let position = q.previous.flatMap { previous in updated.tasks.firstIndex { $0.id == previous } }
                .map { $0 + 1 } ?? 0
            updated.tasks.insert(item, at: position)
            try persist(updated)
            return apiObject(snapshot.tasks.first { $0.id == id }!)
        }
        if let q = query as? GTLRTasksQuery_TasksPatch, let body = q.bodyObject as? GTLRTasks_Task,
           let index = snapshot.tasks.firstIndex(where: { $0.id == q.task && $0.listID == q.tasklist })
        {
            try validateCondition(q, task: snapshot.tasks[index])
            var updated = snapshot
            updated.tasks[index].title = body.title ?? updated.tasks[index].title
            updated.tasks[index].notes = body.notes ?? updated.tasks[index].notes
            if let status = body.status { updated.tasks[index].isCompleted = status == "completed" }
            if let due = body.jsonValue(forKey: "due") {
                updated.tasks[index].due = (due as? String).flatMap { TaskDay(String($0.prefix(10))) }
            }
            updated.tasks[index].etag = UUID().uuidString
            try persist(updated)
            return apiObject(snapshot.tasks[index])
        }
        if let q = query as? GTLRTasksQuery_TasksDelete {
            guard let task = snapshot.tasks.first(where: { $0.id == q.task && $0.listID == q.tasklist })
            else { throw responseError(404, "Task not found") }
            try validateCondition(q, task: task)
            var updated = snapshot
            updated.tasks.removeAll { $0.listID == q.tasklist && ($0.id == q.task || $0.parentID == q.task) }
            try persist(updated)
            return nil
        }
        if let q = query as? GTLRTasksQuery_TasklistsInsert, let body = q.bodyObject as? GTLRTasks_TaskList {
            let list = TaskList(id: UUID().uuidString, title: body.title ?? L10n.tr("新しいリスト"))
            var updated = snapshot
            updated.lists.append(list)
            try persist(updated)
            let result = GTLRTasks_TaskList()
            result.identifier = list.id
            result.title = list.title
            return result
        }
        throw AppFailure(L10n.tr("サンプルAPIが対応していないリクエストです: %@", String(describing: String(describing: type(of: query)))))
    }

    private func apiObject(_ item: ReminderTask) -> GTLRTasks_Task {
        let value = GoogleTasksService.object(item)
        value.identifier = item.remoteID ?? item.id
        value.parent = item.parentID
        value.position = item.position
        value.eTag = item.etag
        return value
    }

    private func validateCondition(_ query: GTLRQuery, task: ReminderTask) throws {
        if let expected = query.additionalHTTPHeaders?["If-Match"], expected != "*", expected != task.etag {
            throw responseError(412, "Precondition Failed")
        }
    }

    private func responseError(_ status: Int, _ description: String) -> NSError {
        NSError(domain: kGTLRErrorObjectDomain, code: status, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func persist(_ updated: TaskSnapshot) throws {
        var updated = updated
        for index in updated.tasks.indices {
            updated.tasks[index].position = String(format: "%020d", index)
        }
        if let fileURL {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        }
        snapshot = updated
    }
}
