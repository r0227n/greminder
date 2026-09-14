import ComposableArchitecture
@testable import GreminderKit
import XCTest

@MainActor
final class NotificationTests: XCTestCase {
    private let scope = NotificationPlanner.scope("test@example.com")
    private var today: TaskDay { TaskDay("2026-09-13")! }
    private var tomorrow: TaskDay { TaskDay("2026-09-14")! }
    private var yesterday: TaskDay { TaskDay("2026-09-12")! }
    private var now: Date { NotificationPlanner.date(day: today, hour: 12, minute: 0) }

    private func fixture() -> (TaskSnapshot, NotificationPreferences, String) {
        let task = ReminderTask(id: "task", remoteID: "remote", listID: "work", title: "通知対象", due: tomorrow)
        let key = NotificationPlanner.key(task: task, scope: scope)
        let preferences = NotificationPreferences(enabled: true, records: [
            key: NotificationRecord(
                date: NotificationPlanner.date(day: yesterday, hour: 10, minute: 15),
                sourceDay: yesterday,
            ),
        ])
        return (TaskSnapshot(lists: [TaskList(id: "work", title: "仕事")], tasks: [task]), preferences, key)
    }

    func testOnlyOverdueDifferentCalendarDaysRequireReview() {
        let (snapshot, initial, _) = fixture()
        var preferences = initial
        let conflicts = NotificationPlanner.update(
            preferences: &preferences,
            snapshot: snapshot,
            scope: scope,
            now: now,
            reviewOverdue: true,
        )
        XCTAssertEqual(conflicts.map(\.title), ["通知対象"])
        XCTAssertEqual(preferences, initial, "A pending confirmation must not change the local notification")

        var sameDay = snapshot
        sameDay.tasks[0].due = yesterday
        XCTAssertTrue(NotificationPlanner.update(
            preferences: &preferences,
            snapshot: sameDay,
            scope: scope,
            now: now,
            reviewOverdue: true,
        ).isEmpty)
    }

    func testYesUpdatesLocalDayAndKeepsLocalClockTime() async {
        let (snapshot, preferences, key) = fixture()
        let store = TestStore(initialState: NotificationFeature.State(preferences: preferences, isLoaded: true)) {
            NotificationFeature()
        } withDependencies: {
            $0.date.now = now
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.tasksUpdated(snapshot, "test@example.com", reviewOverdue: true))
        await store.finish()
        XCTAssertEqual(store.state.conflicts.count, 1)
        await store.send(.resolveConflicts(true))
        await store.finish()
        XCTAssertEqual(
            store.state.preferences.records[key]?.date,
            NotificationPlanner.date(day: tomorrow, hour: 10, minute: 15),
        )
        XCTAssertTrue(store.state.conflicts.isEmpty)
    }

    func testNoPreservesLocalDateAndDoesNotRepeatDuringSameSession() async {
        let (snapshot, preferences, key) = fixture()
        let store = TestStore(initialState: NotificationFeature.State(preferences: preferences, isLoaded: true)) {
            NotificationFeature()
        } withDependencies: {
            $0.date.now = now
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.tasksUpdated(snapshot, "test@example.com", reviewOverdue: true))
        await store.finish()
        await store.send(.resolveConflicts(false))
        await store.finish()
        XCTAssertEqual(store.state.preferences.records[key], preferences.records[key])
        await store.send(.tasksUpdated(snapshot, "test@example.com", reviewOverdue: true))
        await store.finish()
        XCTAssertTrue(store.state.conflicts.isEmpty)
    }

    func testCompletionAndDateRemovalCancelPlannedNotifications() {
        var snapshot = TaskSnapshot.sample(today: tomorrow)
        var preferences = NotificationPreferences(enabled: true)
        _ = NotificationPlanner.update(
            preferences: &preferences,
            snapshot: snapshot,
            scope: scope,
            now: now,
            reviewOverdue: true,
        )
        XCTAssertEqual(
            NotificationPlanner.requests(preferences: preferences, snapshot: snapshot, scope: scope, now: now).count,
            6,
        )
        snapshot.tasks[0].isCompleted = true
        snapshot.tasks[1].due = nil
        _ = NotificationPlanner.update(
            preferences: &preferences,
            snapshot: snapshot,
            scope: scope,
            now: now,
            reviewOverdue: false,
        )
        XCTAssertEqual(
            NotificationPlanner.requests(preferences: preferences, snapshot: snapshot, scope: scope, now: now).count,
            4,
        )
        XCTAssertNil(preferences.records[NotificationPlanner.key(task: snapshot.tasks[0], scope: scope)])
    }

    func testDisabledNotificationsScheduleNothingAndAccountsStaySeparate() {
        let (snapshot, initial, _) = fixture()
        var preferences = initial
        preferences.enabled = false
        XCTAssertTrue(NotificationPlanner.requests(preferences: preferences, snapshot: snapshot, scope: scope, now: now)
            .isEmpty)
        let anotherScope = NotificationPlanner.scope("second@example.com")
        _ = NotificationPlanner.update(
            preferences: &preferences,
            snapshot: snapshot,
            scope: anotherScope,
            now: now,
            reviewOverdue: false,
        )
        XCTAssertEqual(preferences.records.count, 2)
    }

    func testNotificationsInDSTGapMoveForwardOnSameDay() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let day = TaskDay("2026-03-08")!
        let date = NotificationPlanner.date(day: day, hour: 2, minute: 30, timeZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.day, .hour], from: date)
        XCTAssertEqual(parts.day, 8)
        XCTAssertEqual(parts.hour, 3)
    }

    func testTaskTimeSwitchPreservesDueDateAndOtherNotifications() async throws {
        let task = ReminderTask(id: "one", listID: "work", title: "One", due: tomorrow)
        let other = ReminderTask(id: "two", listID: "work", title: "Two", due: tomorrow)
        let snapshot = TaskSnapshot(tasks: [task, other])
        var preferences = NotificationPreferences(enabled: true)
        _ = NotificationPlanner.update(
            preferences: &preferences,
            snapshot: snapshot,
            scope: scope,
            now: now,
            reviewOverdue: false,
        )
        let key = NotificationPlanner.key(task: task, scope: scope)
        let originalDate = preferences.records[key]?.date
        let saved = LockIsolated<NotificationPreferences?>(nil)
        let store = TestStore(initialState: NotificationFeature.State(
            preferences: preferences, snapshot: snapshot, scope: scope, hasTasks: true, isLoaded: true,
        )) { NotificationFeature() } withDependencies: {
            $0.date.now = now
            $0.notifications.saveAndSchedule = { value, requests in
                saved.setValue(value)
                return NotificationReport(access: .authorized, scheduled: requests.count)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.taskNotificationEnabled(task, false))
        await store.receive(\.synchronize)
        await store.receive(\.synchronized)
        XCTAssertEqual(store.state.report.scheduled, 1)
        XCTAssertEqual(store.state.snapshot.tasks[0].due, tomorrow)
        XCTAssertEqual(store.state.preferences.records[key]?.date, originalDate)
        let persisted = try JSONDecoder().decode(
            NotificationPreferences.self,
            from: JSONEncoder().encode(XCTUnwrap(saved.value)),
        )
        XCTAssertEqual(persisted.records[key]?.isEnabled, false)
        await store.send(.taskNotificationEnabled(task, true))
        await store.receive(\.synchronize)
        await store.receive(\.synchronized)
        XCTAssertEqual(store.state.report.scheduled, 2)
        XCTAssertEqual(store.state.preferences.records[key]?.date, originalDate)
    }

    func testLegacyRecordsStayEnabledAndDisabledRecordsDoNotPromptForConflicts() throws {
        let legacy = Data(#"{"date":0,"sourceDay":{"value":"2026-09-14"}}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(NotificationRecord.self, from: legacy).isEnabled)
        let (snapshot, initial, key) = fixture()
        var preferences = initial
        preferences.records[key]?.isEnabled = false
        let conflicts = NotificationPlanner.update(
            preferences: &preferences,
            snapshot: snapshot,
            scope: scope,
            now: now,
            reviewOverdue: true,
        )
        XCTAssertTrue(conflicts.isEmpty)
        XCTAssertEqual(preferences.records[key]?.isEnabled, false)
        XCTAssertTrue(NotificationPlanner.requests(preferences: preferences, snapshot: snapshot, scope: scope, now: now)
            .isEmpty)
    }

    func testInsertAcknowledgementMigratesCustomizedNotificationToRemoteIdentity() {
        var task = ReminderTask(id: "local-id", listID: "work", title: "New task", due: tomorrow)
        let localKey = NotificationPlanner.key(task: task, scope: scope)
        let record = NotificationRecord(
            date: NotificationPlanner.date(day: tomorrow, hour: 18, minute: 45),
            sourceDay: tomorrow,
            isEnabled: false,
        )
        var preferences = NotificationPreferences(enabled: true, records: [localKey: record])
        task.remoteID = "google-id"
        let remoteKey = NotificationPlanner.key(task: task, scope: scope)
        _ = NotificationPlanner.update(
            preferences: &preferences, snapshot: TaskSnapshot(tasks: [task]), scope: scope,
            now: now, reviewOverdue: false,
        )
        XCTAssertNil(preferences.records[localKey])
        XCTAssertEqual(preferences.records[remoteKey], record)

        // Reloading replaces the UI ID with the Google ID but keeps the same record.
        task.id = "google-id"
        _ = NotificationPlanner.update(
            preferences: &preferences, snapshot: TaskSnapshot(tasks: [task]), scope: scope,
            now: now, reviewOverdue: false,
        )
        XCTAssertEqual(preferences.records, [remoteKey: record])
    }

    func testSynchronizationSerializesAndCoalescesToLatestPreferences() async {
        let gate = AsyncStream<Void>.makeStream()
        let savedHours = LockIsolated<[Int]>([])
        let store = TestStore(initialState: NotificationFeature.State(hasTasks: true, isLoaded: true)) {
            NotificationFeature()
        } withDependencies: {
            $0.date.now = now
            $0.notifications.saveAndSchedule = { preferences, _ in
                savedHours.withValue { $0.append(preferences.hour) }
                if preferences.hour == 9 {
                    for await _ in gate.stream {
                        break
                    }
                }
                return NotificationReport(access: .authorized)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.synchronize)
        await store.send(.defaultTimeChanged(NotificationPlanner.date(day: tomorrow, hour: 10, minute: 0)))
        await store.receive(\.synchronize)
        await store.send(.defaultTimeChanged(NotificationPlanner.date(day: tomorrow, hour: 11, minute: 0)))
        await store.receive(\.synchronize)
        XCTAssertEqual(savedHours.value, [9], "No second persistence request may start while the first is pending")
        gate.continuation.yield(())
        gate.continuation.finish()
        await store.receive(\.synchronized)
        await store.receive(\.synchronize)
        await store.receive(\.synchronized)
        XCTAssertEqual(savedHours.value, [9, 11])
        XCTAssertFalse(store.state.isSynchronizing)
        XCTAssertFalse(store.state.needsSynchronization)
    }

    func testInitialLoadIsSingleFlightAndProtectsUnloadedPreferences() async {
        let gate = AsyncStream<Void>.makeStream()
        let calls = LockIsolated(0)
        let store = TestStore(initialState: NotificationFeature.State()) { NotificationFeature() } withDependencies: {
            $0.notifications.load = {
                calls.withValue { $0 += 1 }
                for await _ in gate.stream {
                    break
                }
                return NotificationPreferences(hour: 17)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.start)
        await store.send(.start)
        await store.send(.defaultTimeChanged(now))
        await store.send(.taskTimeChanged(
            ReminderTask(id: "task", listID: "work", title: "Task", due: tomorrow), now,
        ))
        XCTAssertEqual(store.state.preferences, NotificationPreferences())
        XCTAssertEqual(calls.value, 1)
        gate.continuation.yield(())
        gate.continuation.finish()
        await store.receive(\.loaded)
        await store.receive(\.synchronize)
        XCTAssertEqual(store.state.preferences.hour, 17)
        XCTAssertFalse(store.state.isLoading)
        XCTAssertTrue(store.state.isLoaded)
    }

    func testSuccessfulSynchronizationClearsPreviousFailure() async {
        let calls = LockIsolated(0)
        let store = TestStore(initialState: NotificationFeature.State(hasTasks: true, isLoaded: true)) {
            NotificationFeature()
        } withDependencies: {
            $0.date.now = now
            $0.notifications.saveAndSchedule = { _, _ in
                let attempt = calls.withValue { $0 += 1
                    return $0
                }
                if attempt == 1 { throw AppFailure("Unavailable") }
                return NotificationReport(access: .authorized)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.synchronize)
        await store.receive(\.synchronized)
        XCTAssertNotNil(store.state.error)
        await store.send(.synchronize)
        await store.receive(\.synchronized)
        XCTAssertNil(store.state.error)
        XCTAssertEqual(store.state.report.access, .authorized)
    }

    func testInvalidPersistedClockTimesFailDecodingBeforeScheduling() throws {
        for (hour, minute) in [(-1, 0), (24, 0), (9, -1), (9, 60)] {
            let data = try JSONEncoder().encode(NotificationPreferences(hour: hour, minute: minute))
            XCTAssertThrowsError(try JSONDecoder().decode(NotificationPreferences.self, from: data))
        }
        let valid = NotificationPreferences(enabled: true, hour: 23, minute: 59)
        XCTAssertEqual(try JSONDecoder().decode(
            NotificationPreferences.self, from: JSONEncoder().encode(valid),
        ), valid)
    }
}
