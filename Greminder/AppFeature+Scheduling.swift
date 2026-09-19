import ComposableArchitecture
import Foundation

extension AppFeature.State {
    var editorNotificationDate: Date? {
        guard let editor, let due = editor.task.due else { return nil }
        return editor.notificationEdit?.date ?? pendingNotificationEdits[editor.task.id]?.date ?? notifications
            .date(for: editor.task)
            ?? NotificationPlanner.date(
                day: due,
                hour: notifications.preferences.hour,
                minute: notifications.preferences.minute,
            )
    }

    var editorNotificationEnabled: Bool {
        guard let editor, editor.task.due != nil, notifications.preferences.enabled else { return false }
        return editor.notificationEdit?.enabled ?? pendingNotificationEdits[editor.task.id]?.enabled ?? notifications
            .record(for: editor.task)?.isEnabled ?? true
    }
}

extension AppFeature {
    func updateEditorSchedule(_ state: inout State, change: TaskScheduleChange) {
        guard var editor = state.editor else { return }
        let localDate = state.editorNotificationDate ?? NotificationPlanner.date(
            day: editor.task.due ?? state.today,
            hour: state.notifications.preferences.hour,
            minute: state.notifications.preferences.minute,
        )
        var edit = editor.notificationEdit ?? state.pendingNotificationEdits[editor.task.id] ?? TaskNotificationEdit()
        switch change {
        case let .date(day):
            editor.task.due = day
            edit.date = day.map { NotificationPlanner.replacingDay(of: localDate, with: $0) }
            if day == nil { edit.enabled = nil }
        case let .time(date):
            guard editor.task.due != nil else { return }
            edit.date = date
        case let .enabled(enabled):
            if enabled, editor.task.due == nil {
                editor.task.due = state.today
                edit.date = localDate
            }
            edit.enabled = enabled
        }
        editor.notificationEdit = edit
        state.editor = editor
    }

    /// Local notification intents are released only after the task draft passes validation.
    func notificationEffects(_ state: inout State) -> Effect<Action> {
        .send(.notifications(.tasksUpdated(
            state.snapshot,
            state.account,
            reviewOverdue: false,
            edits: state.notifications.isLoaded ? state.pendingNotificationEdits : [:],
        )))
    }
}
