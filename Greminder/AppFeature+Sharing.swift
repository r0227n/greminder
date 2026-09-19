import ComposableArchitecture
import Foundation
import GreminderShare

struct SharedDeletionReview: Equatable, Identifiable {
    var id: String
    var scope: String
    var title: String
}

extension AppFeature.State {
    /// A projection of app state, never another independently mutable source of truth.
    var shareContext: ShareContext? {
        guard hasLoadedTasks,
              let scope = account.map({ "google:" + $0 }) ?? (usesMockAPI ? "sample" : nil) else { return nil }
        let selectedListID: String? = if case let .list(id) = selection { id } else { nil }
        return ShareContext(
            scope: scope, accountName: account ?? L10n.tr("サンプル"),
            lists: snapshot.lists.map { ShareList(id: $0.id, title: $0.title, symbol: $0.symbol) },
            selectedListID: selectedListID, language: L10n.identifier(for: displayLanguage),
            notificationsEnabled: notifications.preferences.enabled,
        )
    }
}

extension AppFeature {
    func publishShareContext(_ state: inout State) {
        guard state.hasLoadedTasks else { return }
        do { try shareInbox.publish(state.shareContext) }
        catch { state.error = L10n.tr("共有ToDoの保存状態を更新できませんでした。\n%@", error.localizedDescription) }
    }

    /// A request keeps its original account and list. Deleted lists never fall back to another list.
    func receiveSharedTasks(_ state: inout State) -> Effect<Action> {
        guard !state.isLoading, state.hasLoadedTasks else { return .none }
        do {
            try shareInbox.publish(state.shareContext)
            guard let context = state.shareContext else { return .none }
            let requests = try shareInbox.requests(context.scope)
            state.sharedDeletionReview = nil
            var changed = false
            for request in requests {
                let id = request.draft.taskID
                guard !state.pending.contains(where: { $0.task.id == id }) else { continue }
                if request.deletionRequested {
                    if let remoteID = request.remoteID {
                        // Resume the exact server deletion after a restart. Never infer
                        // a remote identity from a title or other non-unique content.
                        let task = ReminderTask(
                            id: id,
                            remoteID: remoteID,
                            listID: request.listID,
                            title: request.draft.title,
                        )
                        let matching = state.snapshot.tasks
                            .filter { $0.remoteID == remoteID && $0.listID == request.listID }
                        let removedIDs = matching.reduce(into: Set<String>()) {
                            $0.formUnion(state.snapshot.descendantIDs(of: $1.id))
                        }
                        state.snapshot.tasks.removeAll { removedIDs.contains($0.id) }
                        for id in removedIDs {
                            state.pendingNotificationEdits[id] = nil
                        }
                        state.pending.append(PendingWrite(task: task, isDelete: true))
                        changed = true
                    } else if state.sharedDeletionReview == nil {
                        state.sharedDeletionReview = SharedDeletionReview(
                            id: id,
                            scope: request.scope,
                            title: request.draft.title,
                        )
                    }
                    continue
                }
                guard
                    !state.sharedAwaitingNotification.contains(id),
                    !state.snapshot.tasks.contains(where: { $0.id == id }) else { continue }
                guard state.snapshot.lists.contains(where: { $0.id == request.listID }) else {
                    state.error = L10n.tr("共有ToDoの保存先リストが見つかりません。元のアカウントとリストを確認してください。")
                    continue
                }
                var task = ReminderTask(
                    id: id,
                    remoteID: request.remoteID,
                    listID: request.listID,
                    title: request.draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    notes: request.draft.taskNotes,
                    due: request.draft.dueDay,
                )
                guard TaskInputPolicy.error(for: task) == nil else {
                    state.error = L10n.tr("共有ToDoの入力内容を確認してください。")
                    continue
                }
                if request.phase == .saved {
                    // Preserve local identity until notification settings have been durably saved.
                    guard let index = state.snapshot.tasks.firstIndex(where: { $0.remoteID == request.remoteID }) else {
                        // A successfully created task may already have been removed on another device.
                        try shareInbox.remove([id])
                        continue
                    }
                    task = state.snapshot.tasks[index]
                    task.id = id
                    state.snapshot.tasks[index] = task
                    state.sharedAwaitingNotification.insert(id)
                } else {
                    state.snapshot.tasks.append(task)
                    state.pending.append(PendingWrite(task: task))
                    if request.phase == .sending {
                        state.writeFailed = true
                        state.error = L10n.tr("共有ToDoの同期結果を確認できません。Google Tasksで重複がないことを確認してから再試行するか、このToDoを削除してください。")
                    }
                }
                if task.due != nil {
                    state.pendingNotificationEdits[id] = TaskNotificationEdit(
                        date: request.draft.notificationDate, enabled: request.draft.notificationDate != nil,
                    )
                }
                changed = true
            }
            return changed ? .send(.processQueue) : .none
        } catch {
            state.error = L10n.tr("共有ToDoを読み込めませんでした。\n%@", error.localizedDescription)
            return .none
        }
    }

    func acknowledgeSharedTasks(_ state: inout State) {
        guard !state.sharedAwaitingNotification.isEmpty,
              !state.notifications.isSynchronizing, !state.notifications.needsSynchronization,
              state.pendingNotificationEdits.isEmpty else { return }
        do {
            try shareInbox.remove(state.sharedAwaitingNotification)
            state.sharedAwaitingNotification = []
        } catch { state.error = L10n.tr("共有ToDoの保存状態を更新できませんでした。\n%@", error.localizedDescription) }
    }
}
