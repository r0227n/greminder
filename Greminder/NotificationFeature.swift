import ComposableArchitecture
import Foundation

@Reducer
struct NotificationFeature {
    @ObservableState
    struct State: Equatable {
        var preferences = NotificationPreferences()
        var snapshot = TaskSnapshot()
        var scope = NotificationPlanner.scope(nil)
        var hasTasks = false
        var isLoading = false
        var isLoaded = false
        var reviewOnLoad = true
        var isRequesting = false
        var report = NotificationReport(access: .notDetermined)
        var conflicts: [NotificationConflict] = []
        var ignored: Set<String> = []
        var error: String?
        var revision = 0
        var isSynchronizing = false
        var needsSynchronization = false

        func record(for task: ReminderTask) -> NotificationRecord? {
            preferences.records[NotificationPlanner.key(task: task, scope: scope)]
        }

        func date(for task: ReminderTask) -> Date? { record(for: task)?.date }
    }

    enum Action {
        case start
        case loaded(Result<NotificationPreferences, AppFailure>)
        case tasksUpdated(TaskSnapshot, String?, reviewOverdue: Bool, edits: [String: TaskNotificationEdit] = [:])
        case setEnabled(Bool)
        case accessResult(Result<NotificationAccess, AppFailure>)
        case defaultTimeChanged(Date)
        case taskTimeChanged(ReminderTask, Date)
        case taskNotificationEnabled(ReminderTask, Bool)
        case resolveConflicts(Bool)
        case synchronize
        case synchronized(Int, Result<NotificationReport, AppFailure>)
    }

    @Dependency(\.notifications) var client
    @Dependency(\.date.now) var now

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                guard !state.isLoaded else { return .send(.synchronize) }
                guard !state.isLoading else { return .none }
                state.isLoading = true
                return .run { send in
                    await send(.loaded(Result { try await client.load() }.mapError(AppFailure.init)))
                }
            case let .loaded(.success(preferences)):
                state.isLoading = false
                state.preferences = preferences
                state.isLoaded = true
                state.error = nil
                update(&state, review: true)
                if state.hasTasks { state.reviewOnLoad = false }
                return .send(.synchronize)
            case let .loaded(.failure(error)):
                state.isLoading = false
                state.error = L10n.tr("通知設定を読み込めませんでした。\n%@", String(describing: error.message))
                return .none
            case let .tasksUpdated(snapshot, account, review, edits):
                let scope = NotificationPlanner.scope(account)
                if state.scope != scope { state.conflicts = []
                    state.ignored = []
                }
                state.snapshot = snapshot
                state.scope = scope
                state.hasTasks = true
                state.reviewOnLoad = state.reviewOnLoad || review
                if state.isLoaded { update(&state, review: state.reviewOnLoad)
                    state.reviewOnLoad = false
                    for task in snapshot.tasks {
                        if let edit = edits[task.id] { apply(edit, to: task, state: &state) }
                    }
                }
                // Snapshot migration, explicit edits, and the synchronization barrier
                // form one state transition before an older save can finish.
                return synchronize(&state)
            case let .setEnabled(enabled):
                guard state.isLoaded, !state.isRequesting else { return .none }
                if !enabled {
                    state.preferences.enabled = false
                    state.conflicts = []
                    return .send(.synchronize)
                }
                state.isRequesting = true
                return .run { send in
                    await send(.accessResult(Result { try await client.requestAccess() }.mapError(AppFailure.init)))
                }
            case let .accessResult(.success(access)):
                state.isRequesting = false
                state.report.access = access
                state.preferences.enabled = access == .authorized
                state.error = access == .authorized ? nil : access.label
                update(&state, review: true)
                return .send(.synchronize)
            case let .accessResult(.failure(error)):
                state.isRequesting = false
                state.error = error.message
                return .none
            case let .defaultTimeChanged(date):
                guard state.isLoaded else { return .none }
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                state.preferences.hour = parts.hour ?? 9
                state.preferences.minute = parts.minute ?? 0
                // The default only affects newly encountered tasks; edited task times remain intact.
                return .send(.synchronize)
            case let .taskTimeChanged(task, date):
                guard state.isLoaded, task.due != nil else { return .none }
                apply(TaskNotificationEdit(date: date), to: task, state: &state)
                return .send(.synchronize)
            case let .taskNotificationEnabled(task, enabled):
                guard state.isLoaded, task.due != nil else { return .none }
                apply(TaskNotificationEdit(enabled: enabled), to: task, state: &state)
                return .send(.synchronize)
            case let .resolveConflicts(accept):
                for conflict in state.conflicts {
                    if accept {
                        state.preferences.records[conflict.id] = NotificationRecord(
                            date: NotificationPlanner.replacingDay(of: conflict.localDate, with: conflict.googleDay),
                            sourceDay: conflict.googleDay,
                        )
                    }
                    state.ignored.insert(conflict.id + conflict.googleDay.value)
                }
                state.conflicts = []
                return .send(.synchronize)
            case .synchronize:
                return synchronize(&state)
            case let .synchronized(revision, .success(report)):
                guard revision == state.revision, state.isSynchronizing else { return .none }
                state.isSynchronizing = false
                if !state.needsSynchronization {
                    state.report = report
                    state.error = nil
                }
                return state.needsSynchronization ? .send(.synchronize) : .none
            case let .synchronized(revision, .failure(error)):
                guard revision == state.revision, state.isSynchronizing else { return .none }
                state.isSynchronizing = false
                if !state.needsSynchronization {
                    state.error = L10n.tr("通知を予約できませんでした。\n%@", String(describing: error.message))
                }
                return state.needsSynchronization ? .send(.synchronize) : .none
            }
        }
    }

    private func apply(_ edit: TaskNotificationEdit, to task: ReminderTask, state: inout State) {
        guard let due = task.due else { return }
        let key = NotificationPlanner.key(task: task, scope: state.scope)
        var record = state.preferences.records[key] ?? NotificationRecord(
            date: NotificationPlanner.date(day: due, hour: state.preferences.hour, minute: state.preferences.minute),
            sourceDay: due,
        )
        if let date = edit.date {
            record.date = date
            record.sourceDay = due
        }
        if let enabled = edit.enabled { record.isEnabled = enabled }
        state.preferences.records[key] = record
        state.conflicts.removeAll { $0.id == key }
    }

    private func synchronize(_ state: inout State) -> Effect<Action> {
        guard state.isLoaded else { return .none }
        // Capture only one write at a time. A result revision alone cannot prevent
        // an older effect from reaching persistence after a newer one.
        guard !state.isSynchronizing else {
            state.needsSynchronization = true
            return .none
        }
        state.isSynchronizing = true
        state.needsSynchronization = false
        state.revision += 1
        let revision = state.revision
        let preferences = state.preferences
        let hasTasks = state.hasTasks
        let requests = hasTasks ? NotificationPlanner.requests(
            preferences: preferences,
            snapshot: state.snapshot,
            scope: state.scope,
            now: now,
        ) : []
        return .run { send in
            await send(.synchronized(
                revision,
                Result {
                    if hasTasks {
                        try await client.saveAndSchedule(preferences, requests)
                    } else {
                        // Settings remain usable when task loading fails. An
                        // unknown snapshot must not cancel existing reminders.
                        try await client.savePreferences(preferences)
                    }
                }.mapError(AppFailure.init),
            ))
        }
    }

    private func update(_ state: inout State, review: Bool) {
        guard state.hasTasks else { return }
        let found = NotificationPlanner.update(
            preferences: &state.preferences,
            snapshot: state.snapshot,
            scope: state.scope,
            now: now,
            reviewOverdue: review && state.preferences.enabled,
            ignored: state.ignored,
        )
        // Drop stale dialog rows when a task is changed or completed while the dialog is open.
        let tasks = state.snapshot.tasks.filter { !$0.isCompleted }
        let scope = state.scope
        state.conflicts.removeAll { conflict in
            !tasks
                .contains {
                    NotificationPlanner.key(task: $0, scope: scope) == conflict.id && $0.due == conflict.googleDay
                }
        }
        for conflict in found
            where !state.conflicts.contains(where: { $0.id == conflict.id })
        {
            state.conflicts.append(conflict)
        }
    }
}
