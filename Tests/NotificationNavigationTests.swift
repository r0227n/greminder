import ComposableArchitecture
@testable import GreminderKit
import UserNotifications
import XCTest

@MainActor
final class NotificationNavigationTests: XCTestCase {
    private let task = ReminderTask(id: "local", remoteID: "remote", listID: "work", title: "Notification target")
    private var key: String { NotificationPlanner.key(task: task, scope: NotificationPlanner.scope(nil)) }
    private var snapshot: TaskSnapshot { TaskSnapshot(lists: [TaskList(id: "work", title: "Work")], tasks: [task]) }

    private func store(_ state: AppFeature.State = AppFeature.State()) -> TestStoreOf<AppFeature> {
        var state = state
        state.showsSampleTasks = true
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    func testForegroundTapOpensLinkedListAndDetails() async {
        var state = AppFeature.State()
        state.snapshot = snapshot
        state.showsSearch = true
        state.search = "another task"
        let store = store(state)
        await store.send(.notificationTapped(key))
        await store.receive(\.openSearchResult)
        await store.finish()
        XCTAssertTrue(store.state.showsTaskDetails)
        XCTAssertEqual(store.state.editor?.task.id, task.id)
        XCTAssertEqual(store.state.selection, .list(task.listID))
        XCTAssertEqual(store.state.compactColumn, .detail)
        XCTAssertFalse(store.state.showsSearch)
        XCTAssertNil(store.state.pendingNotificationKey)
    }

    func testColdLaunchTapWaitsForTaskLoadAndSurvivesLocalIDChange() async {
        let gate = AsyncStream<Void>.makeStream()
        var reloaded = snapshot
        reloaded.tasks[0].id = "remote"
        let loadedSnapshot = reloaded
        let store = store()
        store.dependencies.taskClient.load = {
            for await _ in gate.stream {
                break
            }
            return ConnectedTasks(snapshot: loadedSnapshot)
        }
        await store.send(.notificationTapped(key))
        await store.receive(\.reload)
        XCTAssertTrue(store.state.isLoading)
        XCTAssertFalse(store.state.showsTaskDetails)
        XCTAssertEqual(store.state.pendingNotificationKey, key)
        gate.continuation.yield(())
        gate.continuation.finish()
        await store.receive(\.openSearchResult)
        await store.finish()
        XCTAssertTrue(store.state.showsTaskDetails)
        XCTAssertEqual(store.state.editor?.task.id, "remote")
    }

    func testBackgroundTapDuringReloadWaitsForFreshSnapshot() async {
        var state = AppFeature.State()
        state.snapshot = snapshot
        state.hasLoadedTasks = true
        state.isLoading = true
        let store = store(state)
        await store.send(.notificationTapped(key))
        await store.finish()
        XCTAssertFalse(store.state.showsTaskDetails)
        await store.send(.loaded(.success(ConnectedTasks(snapshot: snapshot))))
        await store.receive(\.openSearchResult)
        await store.finish()
        XCTAssertTrue(store.state.showsTaskDetails)
        XCTAssertEqual(store.state.editor?.task.id, task.id)
    }

    func testPresentationMustFinishDismissingBeforeOpeningDetails() async {
        var state = AppFeature.State()
        state.snapshot = snapshot
        state.showsSettings = true
        let store = store(state)
        await store.send(.notificationTapped(key))
        XCTAssertFalse(store.state.showsSettings)
        await store.send(.loaded(.success(ConnectedTasks(snapshot: snapshot))))
        await store.finish()
        XCTAssertFalse(store.state.showsTaskDetails)
        await store.send(.notificationPresentationDismissed)
        await store.receive(\.openSearchResult)
        await store.finish()
        XCTAssertTrue(store.state.showsTaskDetails)
    }

    func testNotificationFromNestedSettingsWaitsBeforeReplacingCurrentDetails() async {
        let current = ReminderTask(id: "current", listID: "work", title: "Currently editing")
        var state = AppFeature.State()
        state.snapshot = snapshot
        state.snapshot.tasks.append(current)
        state.editor = TaskEditor(id: "editor", task: current, isNew: false)
        state.showsTaskDetails = true
        state.showsSettings = true
        let store = store(state)

        await store.send(.notificationTapped(key))
        XCTAssertFalse(store.state.showsSettings)
        XCTAssertTrue(store.state.waitsForNotificationDismissal)
        XCTAssertEqual(store.state.editor?.task.id, current.id)

        await store.send(.notificationPresentationDismissed)
        await store.receive(\.openSearchResult)
        await store.finish()
        XCTAssertFalse(store.state.waitsForNotificationDismissal)
        XCTAssertNil(store.state.pendingNotificationKey)
        XCTAssertTrue(store.state.showsTaskDetails)
        XCTAssertEqual(store.state.editor?.task.id, task.id)
    }

    func testListCreationCompletionResumesNotificationAfterSheetDismissal() async {
        for succeeds in [true, false] {
            var state = AppFeature.State()
            state.snapshot = snapshot
            state.isLoading = true
            state.showsNewList = true
            let store = store(state)

            await store.send(.notificationTapped(key))
            await store.send(.notificationPresentationDismissed)
            await store.receive(\.resumeNotificationNavigation)
            XCTAssertTrue(store.state.isLoading)
            XCTAssertFalse(store.state.showsTaskDetails)
            XCTAssertEqual(store.state.pendingNotificationKey, key)

            let result: Result<TaskList, AppFailure> = succeeds
                ? .success(TaskList(id: "new", title: "New list")) : .failure(AppFailure("Offline"))
            await store.send(.listAdded(result))
            await store.receive(\.openSearchResult)
            await store.finish()
            XCTAssertFalse(store.state.isLoading)
            XCTAssertNil(store.state.pendingNotificationKey)
            XCTAssertTrue(store.state.showsTaskDetails)
            XCTAssertEqual(store.state.editor?.task.id, task.id)
            XCTAssertEqual(store.state.selection, .list(task.listID))
        }
    }

    func testListCreationCompletionStillWaitsForSheetDismissal() async {
        for succeeds in [true, false] {
            var state = AppFeature.State()
            state.snapshot = snapshot
            state.isLoading = true
            state.showsNewList = true
            let store = store(state)

            await store.send(.notificationTapped(key))
            let result: Result<TaskList, AppFailure> = succeeds
                ? .success(TaskList(id: "new", title: "New list")) : .failure(AppFailure("Offline"))
            await store.send(.listAdded(result))
            await store.receive(\.resumeNotificationNavigation)
            XCTAssertFalse(store.state.isLoading)
            XCTAssertTrue(store.state.waitsForNotificationDismissal)
            XCTAssertFalse(store.state.showsTaskDetails)

            await store.send(.notificationPresentationDismissed)
            await store.receive(\.openSearchResult)
            await store.finish()
            XCTAssertNil(store.state.pendingNotificationKey)
            XCTAssertTrue(store.state.showsTaskDetails)
            XCTAssertEqual(store.state.editor?.task.id, task.id)
        }
    }

    func testDeletedTaskOrDifferentAccountNeverOpensAnotherTask() async {
        for account in [nil, "another@example.com"] as [String?] {
            var state = AppFeature.State()
            state.snapshot = account == nil ? TaskSnapshot(lists: snapshot.lists) : snapshot
            state.hasLoadedTasks = true
            state.account = account
            let store = store(state)
            await store.send(.notificationTapped(key))
            await store.receive(\.resumeNotificationNavigation)
            await store.finish()
            XCTAssertFalse(store.state.showsTaskDetails)
            XCTAssertNil(store.state.pendingNotificationKey)
            XCTAssertNotNil(store.state.error)
        }
    }

    func testFailedColdLoadRetainsTapForRetry() async {
        var state = AppFeature.State()
        state.isLoading = true
        let store = store(state)
        await store.send(.notificationTapped(key))
        await store.finish()
        await store.send(.loaded(.failure(AppFailure("Offline"))))
        XCTAssertEqual(store.state.pendingNotificationKey, key)
        await store.send(.loaded(.success(ConnectedTasks(snapshot: snapshot))))
        await store.receive(\.openSearchResult)
        await store.finish()
        XCTAssertTrue(store.state.showsTaskDetails)
    }

    func testTapBufferKeepsLatestTapBeforeRootSubscribes() async {
        let buffer = NotificationResponseBuffer()
        buffer.receive("old")
        buffer.receive(key)
        var iterator = buffer.stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, key)
        buffer.receive("next")
        let next = await iterator.next()
        XCTAssertEqual(next, "next")
    }

    func testRequestPayloadAndLegacyIdentifierUseSameTaskIdentity() {
        let notification = ScheduledTaskNotification(
            id: "greminder.task." + key, title: task.title, listTitle: "Work", date: Date(),
        )
        let request = notification.makeRequest(trigger: UNTimeIntervalNotificationTrigger(
            timeInterval: 5,
            repeats: false,
        ))
        XCTAssertEqual(request.content.userInfo[NotificationRouting.taskKeyField] as? String, key)
        XCTAssertEqual(
            NotificationRouting.key(request: request, actionIdentifier: UNNotificationDefaultActionIdentifier),
            key,
        )
        XCTAssertNil(NotificationRouting.key(request: request, actionIdentifier: UNNotificationDismissActionIdentifier))
        let legacy = UNNotificationRequest(
            identifier: notification.id,
            content: UNMutableNotificationContent(),
            trigger: nil,
        )
        XCTAssertEqual(
            NotificationRouting.key(request: legacy, actionIdentifier: UNNotificationDefaultActionIdentifier),
            key,
        )
    }
}
