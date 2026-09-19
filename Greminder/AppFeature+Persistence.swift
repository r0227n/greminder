import ComposableArchitecture
import Foundation

extension AppFeature {
    func reducePersistence(into state: inout State, action: Action) -> Effect<Action>? {
        switch action {
        case let .requestDelete(id):
            guard !state.isLoading, !state.showsVoice else { return Effect.none }
            state.deleteCandidate = state.snapshot.tasks.first { $0.id == id }
            return Effect.none
        case .swipeDelete, .confirmDelete:
            guard !state.isLoading, !state.showsVoice else { return Effect.none }
            let taskID: String
            if case let .swipeDelete(id) = action {
                taskID = id
            } else if let candidate = state.deleteCandidate {
                taskID = candidate.id
            } else {
                return Effect.none
            }
            guard let task = state.snapshot.tasks.first(where: { $0.id == taskID }) else { return Effect.none }
            // Swipe actions already express the deletion intent; use the same queue and
            // descendant cleanup as confirmed deletion without presenting another dialog.
            state.deleteCandidate = nil
            let removedIDs = state.snapshot.descendantIDs(of: task.id)
            let previousHead = state.pending.first?.id
            let inFlightID = state.isSaving ? previousHead : nil
            // Persist cancellation before removing the visible draft, or a failed disk write
            // could silently re-create it the next time the inbox is imported.
            let inFlightTasks = state.pending.filter { $0.id == inFlightID }.map(\.task)
            do {
                try shareInbox.requestDeletion(removedIDs, Set(inFlightTasks.map(\.id)))
                state.sharedAwaitingNotification.subtract(removedIDs)
            } catch {
                state.error = L10n.tr("共有ToDoの保存状態を更新できませんでした。\n%@", error.localizedDescription)
                return Effect.none
            }
            if let editor = state.editor, removedIDs.contains(editor.task.id) {
                state.editor = nil
                state.showsTaskDetails = false
            }
            state.pending.removeAll { removedIDs.contains($0.task.id) && $0.id != inFlightID }
            state.snapshot.tasks.removeAll { removedIDs.contains($0.id) }
            for id in removedIDs {
                state.pendingNotificationEdits[id] = nil
            }
            // Also delete any descendant whose insert is still running; it can finish
            // after its parent was removed from the local snapshot.
            let toDelete = [task] + inFlightTasks.filter { $0.id != task.id && removedIDs.contains($0.id) }
            for candidate in toDelete
                where candidate.remoteID != nil || inFlightTasks.contains(where: { $0.id == candidate.id })
            {
                state.pending.append(PendingWrite(task: candidate, isDelete: true))
            }
            if !state.isSaving, previousHead != state.pending.first?.id {
                state.writeFailed = false
                state.error = nil
            }
            return .merge(.send(.processQueue), .send(.checkSharedTasks))
        case .processQueue:
            let notificationUpdate = Effect<Action>.merge(
                notificationEffects(&state),
                state.pendingNotificationKey != nil && state.editor == nil && !state.waitsForNotificationDismissal
                    ? .send(.resumeNotificationNavigation) : .none,
            )
            if state.pending.isEmpty, state.reloadAfterWrites {
                state.reloadAfterWrites = false
                return .merge(notificationUpdate, .send(.reload))
            }
            guard !state.isSaving, !state.writeFailed,
                  var write = state.pending.first else { return notificationUpdate }
            state.isSaving = true
            if let current = state.snapshot.tasks.first(where: { $0.id == write.task.id }) {
                write.task.remoteID = current.remoteID
                write.task.etag = current.etag
            }
            let previous = write.previousID.flatMap { id in state.snapshot.tasks.first {
                $0.id == id && $0.parentID == write.task.parentID && $0.listID == write.task.listID
            }?.remoteID }
            let parent = write.task.parentID.flatMap { id in state.snapshot.tasks.first { $0.id == id }?.remoteID }
            return .merge(notificationUpdate, .run { [write] send in
                do {
                    let saved: ReminderTask
                    if write.isDelete {
                        if write.task.remoteID != nil {
                            try await tasks.delete(write.task)
                            try shareInbox.remove([write.task.id])
                        }
                        saved = write.task
                    } else {
                        try shareInbox.stage(write.task)
                        saved = try await tasks.save(write.task, previous, parent)
                        do { try shareInbox.receipt(saved) } catch {
                            // The server has already inserted the task. Preserve its ID even if
                            // the local receipt fails, so Retry never issues a second insertion.
                            await send(.writeFinished(write.id, .success(saved)))
                            await send(.sharePersistenceFailed(AppFailure(error)))
                            return
                        }
                    }
                    await send(.writeFinished(write.id, .success(saved)))
                } catch { await send(.writeFinished(write.id, .failure(AppFailure(error)))) }
            })
        case let .writeFinished(id, .success(task)):
            guard state.pending.first?.id == id else { return Effect.none }
            state.pending.removeFirst()
            state.isSaving = false
            if task.id.hasPrefix("share-"), state.snapshot.tasks.contains(where: { $0.id == task.id }) {
                state.sharedAwaitingNotification.insert(task.id)
            }
            if let index = state.snapshot.tasks.firstIndex(where: { $0.id == task.id }) {
                state.snapshot.tasks[index].remoteID = task.remoteID
                state.snapshot.tasks[index].etag = task.etag
            }
            // Propagate remote identity to every queued edit/delete, including deleted rows.
            for index in state.pending.indices where state.pending[index].task.id == task.id {
                state.pending[index].task.remoteID = task.remoteID
                state.pending[index].task.etag = task.etag
            }
            if state.editor?.task.id == task.id {
                state.editor?.task.remoteID = task.remoteID
                state.editor?.task.etag = task.etag
            }
            if state.pending.isEmpty { state.message = L10n.tr("保存しました") }
            return .send(.processQueue)
        case let .writeFinished(id, .failure(error)):
            guard let write = state.pending.first, write.id == id else { return Effect.none }
            state.isSaving = false
            if !write.isDelete, !state.snapshot.tasks.contains(where: { $0.id == write.task.id }) {
                // A transport error does not prove the insert failed on the server.
                // The durable deletion request remains until its outcome is resolved.
                state.pending.removeFirst()
                state.pending.removeAll { $0.task.id == write.task.id && $0.task.remoteID == nil }
                return .merge(.send(.processQueue), .send(.checkSharedTasks))
            }
            state.writeFailed = true
            state.error = L10n.tr("保存できませんでした。入力は保持されています。\n%@", String(describing: error.message))
            return Effect.none
        case .retryWrites:
            state.writeFailed = false
            state.error = nil
            return .send(.processQueue)
        default: return nil
        }
    }
}
