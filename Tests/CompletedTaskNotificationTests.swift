import ComposableArchitecture
import Foundation
@testable import GreminderKit
import XCTest

@MainActor
final class CompletedTaskNotificationTests: XCTestCase {
    private let account = "completed@example.com"
    private let day = TaskDay("2030-09-21")!
    private var now: Date { NotificationPlanner.date(day: day, hour: 8, minute: 0) }
    private var customDate: Date { NotificationPlanner.date(day: day, hour: 18, minute: 45) }
    private var scope: String { NotificationPlanner.scope(account) }

    func testExplicitOffAndCustomTimeSurviveResyncRestartAndReopening() async throws {
        try await assertPersistenceAfterCompletion(enabled: false)
    }

    func testExplicitOnAndCustomTimeScheduleOnlyAfterReopening() async throws {
        try await assertPersistenceAfterCompletion(enabled: true)
    }

    private func assertPersistenceAfterCompletion(enabled: Bool) async throws {
        var task = ReminderTask(
            id: "task", remoteID: "remote", listID: "work", title: "Completed", due: day, isCompleted: true,
        )
        let snapshot = TaskSnapshot(tasks: [task])
        let expected = NotificationRecord(date: customDate, sourceDay: day, isEnabled: enabled)
        let persisted = LockIsolated<Data?>(nil)
        let requests = LockIsolated<[ScheduledTaskNotification]>([])
        let client = NotificationClient(
            load: {
                try JSONDecoder().decode(NotificationPreferences.self, from: XCTUnwrap(persisted.value))
            },
            savePreferences: { _ in
                XCTFail("This test always has a task snapshot")
                return NotificationReport(access: .authorized)
            },
            saveAndSchedule: { preferences, scheduled in
                try persisted.setValue(JSONEncoder().encode(preferences))
                requests.setValue(scheduled)
                return NotificationReport(access: .authorized, scheduled: scheduled.count)
            },
            requestAccess: { .authorized },
        )
        let store = TestStore(initialState: NotificationFeature.State(
            preferences: NotificationPreferences(enabled: true), isLoaded: true,
        )) { NotificationFeature() } withDependencies: {
            $0.date.now = now
            $0.notifications = client
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.tasksUpdated(
            snapshot, account, reviewOverdue: true,
            edits: [task.id: TaskNotificationEdit(date: customDate, enabled: enabled)],
        ))
        await store.receive(\.synchronized)
        XCTAssertEqual(store.state.record(for: task), expected)
        XCTAssertTrue(requests.value.isEmpty)
        await store.send(.tasksUpdated(snapshot, account, reviewOverdue: true))
        await store.receive(\.synchronized)
        await store.finish()
        XCTAssertEqual(store.state.record(for: task), expected)
        XCTAssertTrue(requests.value.isEmpty)

        let restarted = TestStore(initialState: NotificationFeature.State(
            snapshot: snapshot, scope: scope, hasTasks: true,
        )) { NotificationFeature() } withDependencies: {
            $0.date.now = now
            $0.notifications = client
        }
        restarted.exhaustivity = .off(showSkippedAssertions: false)
        await restarted.send(.start)
        await restarted.receive(\.loaded)
        await restarted.receive(\.synchronize)
        await restarted.receive(\.synchronized)
        XCTAssertEqual(restarted.state.record(for: task), expected)
        XCTAssertTrue(requests.value.isEmpty)

        task.isCompleted = false
        await restarted.send(.tasksUpdated(TaskSnapshot(tasks: [task]), account, reviewOverdue: true))
        await restarted.receive(\.synchronized)
        await restarted.finish()
        XCTAssertEqual(restarted.state.record(for: task), expected)
        XCTAssertEqual(requests.value.map(\.date), enabled ? [customDate] : [])
    }

    func testCompletedDetailEditsRemainSavedAfterParentClearsPendingEditsAndReopensTask() async {
        let task = ReminderTask(
            id: "task", remoteID: "remote", listID: "work", title: "Completed", due: day, isCompleted: true,
        )
        let snapshot = TaskSnapshot(lists: [TaskList(id: "work", title: "Work")], tasks: [task])
        let expected = NotificationRecord(date: customDate, sourceDay: day, isEnabled: false)
        let saved = LockIsolated<NotificationPreferences?>(nil)
        let scheduled = LockIsolated<[ScheduledTaskNotification]>([])
        let writes = LockIsolated<[ReminderTask]>([])
        var state = AppFeature.State()
        state.account = account
        state.hasLoadedTasks = true
        state.snapshot = snapshot
        state.notifications = NotificationFeature.State(
            preferences: NotificationPreferences(enabled: true), snapshot: snapshot,
            scope: scope, hasTasks: true, isLoaded: true,
        )
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.date.now = now
            $0.notifications.saveAndSchedule = { preferences, requests in
                saved.setValue(preferences)
                scheduled.setValue(requests)
                return NotificationReport(access: .authorized, scheduled: requests.count)
            }
            $0.taskClient.save = { task, _, _ in
                writes.withValue { $0.append(task) }
                return task
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openDetails(task.id))
        await store.receive(\.notifications.synchronized)
        await store.send(.editorSchedule(task.id, .enabled(false)))
        XCTAssertEqual(store.state.pendingNotificationEdits[task.id]?.enabled, false)
        await store.receive(\.notifications.tasksUpdated)
        XCTAssertTrue(store.state.pendingNotificationEdits.isEmpty)
        await store.receive(\.notifications.synchronized)
        XCTAssertEqual(store.state.notifications.record(for: task)?.isEnabled, false)

        await store.send(.editorSchedule(task.id, .time(customDate)))
        XCTAssertEqual(store.state.pendingNotificationEdits[task.id]?.date, customDate)
        await store.receive(\.notifications.tasksUpdated)
        XCTAssertTrue(store.state.pendingNotificationEdits.isEmpty)
        await store.receive(\.notifications.synchronized)
        await store.send(.saveDetails(task.id))
        await store.receive(\.notifications.synchronized)
        await store.send(.notifications(.tasksUpdated(snapshot, account, reviewOverdue: true)))
        await store.receive(\.notifications.synchronized)
        XCTAssertEqual(store.state.notifications.record(for: task), expected)
        XCTAssertEqual(store.state.editorNotificationDate, customDate)
        XCTAssertFalse(store.state.editorNotificationEnabled)
        XCTAssertTrue(scheduled.value.isEmpty)
        XCTAssertTrue(writes.value.isEmpty)

        await store.send(.toggleComplete(task.id))
        await store.receive(\.writeFinished)
        await store.receive(\.notifications.synchronized)
        await store.finish()
        XCTAssertEqual(writes.value.map(\.isCompleted), [false])
        XCTAssertEqual(store.state.snapshot.tasks.first?.isCompleted, false)
        XCTAssertEqual(store.state.notifications.record(for: task), expected)
        XCTAssertEqual(saved.value?.records[NotificationPlanner.key(task: task, scope: scope)], expected)
        XCTAssertTrue(store.state.pendingNotificationEdits.isEmpty)
        XCTAssertTrue(scheduled.value.isEmpty)
    }

    func testIndividualEditsOnCompletedTaskArePersistedWithoutScheduling() async {
        let task = ReminderTask(id: "task", listID: "work", title: "Completed", due: day, isCompleted: true)
        let saved = LockIsolated<NotificationPreferences?>(nil)
        let store = TestStore(initialState: NotificationFeature.State(
            preferences: NotificationPreferences(enabled: true), snapshot: TaskSnapshot(tasks: [task]),
            scope: scope, hasTasks: true, isLoaded: true,
        )) { NotificationFeature() } withDependencies: {
            $0.date.now = now
            $0.notifications.saveAndSchedule = { preferences, requests in
                saved.setValue(preferences)
                XCTAssertTrue(requests.isEmpty)
                return NotificationReport(access: .authorized)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.taskNotificationEnabled(task, false))
        await store.receive(\.synchronize)
        await store.receive(\.synchronized)
        await store.send(.taskTimeChanged(task, customDate))
        await store.receive(\.synchronize)
        await store.receive(\.synchronized)
        await store.send(.tasksUpdated(TaskSnapshot(tasks: [task]), account, reviewOverdue: true))
        await store.receive(\.synchronized)
        await store.finish()
        let key = NotificationPlanner.key(task: task, scope: scope)
        XCTAssertEqual(
            saved.value?.records[key],
            NotificationRecord(date: customDate, sourceDay: day, isEnabled: false),
        )
    }

    func testCompletedRecordMigratesRemoteIdentityAndIsPrunedOnlyAfterRemoval() {
        var task = ReminderTask(id: "local", listID: "work", title: "Completed", due: day, isCompleted: true)
        let localKey = NotificationPlanner.key(task: task, scope: scope)
        let expected = NotificationRecord(date: customDate, sourceDay: day, isEnabled: false)
        var preferences = NotificationPreferences(enabled: true, records: [localKey: expected])
        task.remoteID = "remote"
        let remoteKey = NotificationPlanner.key(task: task, scope: scope)
        let conflicts = NotificationPlanner.update(
            preferences: &preferences, snapshot: TaskSnapshot(tasks: [task]), scope: scope,
            now: customDate.addingTimeInterval(86400), reviewOverdue: true,
        )
        XCTAssertEqual(preferences.records, [remoteKey: expected])
        XCTAssertTrue(conflicts.isEmpty)
        XCTAssertTrue(NotificationPlanner.requests(
            preferences: preferences, snapshot: TaskSnapshot(tasks: [task]), scope: scope, now: now,
        ).isEmpty)

        task.id = "remote"
        _ = NotificationPlanner.update(
            preferences: &preferences, snapshot: TaskSnapshot(tasks: [task]), scope: scope,
            now: now, reviewOverdue: true,
        )
        XCTAssertEqual(preferences.records, [remoteKey: expected])
        _ = NotificationPlanner.update(
            preferences: &preferences, snapshot: TaskSnapshot(), scope: scope, now: now, reviewOverdue: false,
        )
        XCTAssertTrue(preferences.records.isEmpty)
    }
}
