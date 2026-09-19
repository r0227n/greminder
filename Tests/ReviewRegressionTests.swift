import ComposableArchitecture
import Foundation
@testable import GreminderKit
import GreminderShare
import XCTest

@MainActor
final class ReviewRegressionTests: XCTestCase {
    func testCompletedListExcludesUnfinishedChildrenFromRowsAndCount() {
        let parent = ReminderTask(id: "parent", listID: "work", title: "Done", isCompleted: true)
        let child = ReminderTask(id: "child", listID: "work", title: "Still open", parentID: parent.id)
        let completedChild = ReminderTask(
            id: "completed-child", listID: "work", title: "Done too", isCompleted: true, parentID: parent.id,
        )
        var state = AppFeature.State()
        state.snapshot.tasks = [parent, child, completedChild]
        state.selection = .completed

        XCTAssertEqual(state.matchingTasks.map(\.id), [parent.id, completedChild.id])
        XCTAssertEqual(state.visibleTasks.map(\.id), [parent.id, completedChild.id])
        XCTAssertEqual(state.visibleCount, 2)
        XCTAssertEqual(state.snapshot.tasks(for: .all, today: state.today), [child])
    }

    func testStaleRowActionsStillSaveThePreviousValidEditor() async {
        for action in [
            AppFeature.Action.openDetails("removed"),
            .openSearchResult("removed"),
            .toggleComplete("removed"),
        ] {
            let task = ReminderTask(id: "task", remoteID: "remote", listID: "work", title: "Original")
            var state = AppFeature.State()
            state.snapshot.tasks = [task]
            var edited = task
            edited.title = "Changed"
            state.editor = TaskEditor(id: "editor", task: edited, isNew: false)
            let saved = LockIsolated<[ReminderTask]>([])
            let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
                $0.taskClient.save = { task, _, _ in
                    saved.withValue { $0.append(task) }
                    return task
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(action)
            await store.receive(\.writeFinished)
            await store.finish()

            XCTAssertEqual(saved.value, [edited])
            XCTAssertTrue(store.state.pending.isEmpty)
            XCTAssertNil(store.state.editor)
        }
    }

    func testShareContextTracksSelectionLanguageAndLoadedNotificationPreferencesImmediately() async {
        var state = AppFeature.State()
        state.hasLoadedTasks = true
        state.account = "a@example.com"
        state.snapshot.lists = [TaskList(id: "work", title: "Work")]
        let published = LockIsolated<ShareContext?>(nil)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.defaultAppStorage = defaults
            $0.date.now = Date(timeIntervalSince1970: 1_800_000_000)
            $0.shareInbox.publish = { published.setValue($0) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.select(.list("work")))
        await store.finish()
        XCTAssertEqual(published.value?.selectedListID, "work")

        await store.send(.displayLanguageChanged(.english))
        XCTAssertEqual(published.value?.language, "en")

        var preferences = NotificationPreferences()
        preferences.enabled = true
        await store.send(.notifications(.loaded(.success(preferences))))
        await store.finish()
        XCTAssertEqual(published.value?.notificationsEnabled, true)

        await store.send(.notifications(.setEnabled(false)))
        await store.finish()
        XCTAssertEqual(published.value?.notificationsEnabled, false)

        await store.send(.listAdded(.success(TaskList(id: "new", title: "New"))))
        XCTAssertEqual(published.value?.selectedListID, "new")
        XCTAssertEqual(published.value?.lists.map(\.id), ["work", "new"])
    }

    func testSharedReceiptWaitsUntilItsNotificationEditsAreDurablySaved() async {
        let day = TaskDay("2026-09-21")!
        let task = ReminderTask(id: "share-task", remoteID: "remote", listID: "work", title: "Shared", due: day)
        let date = NotificationPlanner.date(day: day, hour: 18, minute: 30)
        var state = AppFeature.State()
        state.snapshot.tasks = [task]
        state.sharedAwaitingNotification = [task.id]
        state.pendingNotificationEdits[task.id] = TaskNotificationEdit(date: date, enabled: false)
        state.notifications.isLoaded = true
        state.notifications.isSynchronizing = true
        state.notifications.revision = 4
        let removed = LockIsolated<Set<String>>([])
        let gate = AsyncStream<Void>.makeStream()
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.date.now = Date(timeIntervalSince1970: 0)
            $0.shareInbox.remove = { ids in removed.withValue { $0.formUnion(ids) } }
            $0.notifications.saveAndSchedule = { preferences, _ in
                let key = NotificationPlanner.key(task: task, scope: NotificationPlanner.scope(nil))
                XCTAssertEqual(preferences.records[key]?.date, date)
                XCTAssertEqual(preferences.records[key]?.isEnabled, false)
                for await _ in gate.stream {
                    break
                }
                return NotificationReport(access: .authorized)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // An earlier save has finished, but the shared edits have not reached the child yet.
        await store.send(.notifications(.synchronized(4, .success(NotificationReport(access: .authorized)))))
        XCTAssertTrue(removed.value.isEmpty)
        XCTAssertFalse(store.state.pendingNotificationEdits.isEmpty)

        await store.send(.processQueue)
        await store.receive(\.notifications.tasksUpdated)
        XCTAssertTrue(store.state.pendingNotificationEdits.isEmpty)
        XCTAssertTrue(store.state.notifications.isSynchronizing)
        XCTAssertTrue(removed.value.isEmpty)

        gate.continuation.yield(())
        gate.continuation.finish()
        await store.receive(\.notifications.synchronized)
        await store.finish()
        XCTAssertEqual(removed.value, [task.id])
        XCTAssertTrue(store.state.sharedAwaitingNotification.isEmpty)
    }
}
