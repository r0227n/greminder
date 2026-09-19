import ComposableArchitecture
import Foundation
@testable import GreminderKit
import GreminderShare
import XCTest

@MainActor
final class SharedCancellationRegressionTests: XCTestCase {
    private let context = ShareContext(
        scope: "google:test@example.com", accountName: "test@example.com",
        lists: [ShareList(id: "work", title: "Work")], selectedListID: "work",
        language: "en", notificationsEnabled: false,
    )

    private func fixture(remoteID: String? = nil) throws -> (ShareInbox, AppFeature.State, UUID, ReminderTask) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = ShareInbox(directory: directory)
        let draft = ShareDraft(title: "Shared task")
        try inbox.publish(context)
        try inbox.enqueue([draft], context: context, listID: "work")
        try inbox.markSending(taskID: draft.taskID, title: draft.title, notes: "", due: nil)
        if let remoteID { try inbox.markSaved(taskID: draft.taskID, remoteID: remoteID) }
        let task = ReminderTask(id: draft.taskID, remoteID: remoteID, listID: "work", title: draft.title)
        let write = PendingWrite(task: task)
        var state = AppFeature.State()
        state.account = "test@example.com"
        state.hasLoadedTasks = true
        state.snapshot = TaskSnapshot(lists: [TaskList(id: "work", title: "Work")], tasks: [task])
        state.pending = [write]
        state.isSaving = true
        return (inbox, state, write.id, task)
    }

    private func client(_ inbox: ShareInbox) -> ShareInboxClient {
        ShareInboxClient(
            requests: { try inbox.requests(scope: $0) },
            stage: { try inbox.markSending(taskID: $0.id, title: $0.title, notes: $0.notes, due: $0.due?.date) },
            receipt: { if let remoteID = $0.remoteID { try inbox.markSaved(taskID: $0.id, remoteID: remoteID) } },
            requestDeletion: { try inbox.requestDeletion(taskIDs: $0, inFlightTaskIDs: $1) },
            confirmDeletion: { try inbox.confirmDeletion(taskID: $0, scope: $1) },
            remove: { try inbox.remove(taskIDs: $0) },
        )
    }

    func testCommittedInsertWithLostResponseKeepsDeletionReviewAfterRestart() async throws {
        let (inbox, initialState, _, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        var state = initialState
        state.isSaving = false
        let server = LockIsolated<[ReminderTask]>([])
        let gate = AsyncStream<Void>.makeStream()
        let committed = AsyncStream<Void>.makeStream()
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.shareInbox = client(inbox)
            $0.taskClient.save = { task, _, _ in
                var saved = task
                saved.id = "server-id"
                saved.remoteID = "server-id"
                let committedTask = saved
                server.withValue { $0.append(committedTask) }
                committed.continuation.yield(())
                for await _ in gate.stream {
                    break
                }
                throw URLError(.timedOut)
            }
            $0.taskClient.delete = { _ in XCTFail("Unknown remote identities must not be guessed") }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.processQueue)
        for await _ in committed.stream {
            break
        }
        committed.continuation.finish()
        await store.send(.swipeDelete(task.id))
        await store.receive(\.checkSharedTasks)
        gate.continuation.yield(())
        gate.continuation.finish()
        await store.receive(\.writeFinished)
        await store.receive(\.checkSharedTasks)
        await store.finish()
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertTrue(store.state.snapshot.tasks.isEmpty)
        XCTAssertEqual(store.state.sharedDeletionReview?.id, task.id)
        XCTAssertEqual(try inbox.requests(scope: context.scope).first?.deletionRequested, true)

        var restartedState = AppFeature.State()
        restartedState.account = state.account
        restartedState.hasLoadedTasks = true
        restartedState.snapshot = TaskSnapshot(lists: state.snapshot.lists, tasks: server.value)
        let restarted = TestStore(initialState: restartedState) { AppFeature() } withDependencies: {
            $0.shareInbox = client(ShareInbox(directory: inbox.directory))
            $0.taskClient.save = { task, _, _ in XCTFail("Never repeat the cancelled insert")
                return task
            }
            $0.taskClient.delete = { _ in XCTFail("Matching titles do not establish identity") }
        }
        restarted.exhaustivity = .off(showSkippedAssertions: false)
        await restarted.send(.checkSharedTasks)
        await restarted.send(.retryWrites)
        await restarted.finish()
        XCTAssertTrue(restarted.state.pending.isEmpty)
        XCTAssertEqual(restarted.state.snapshot.tasks, server.value)
        let review = try XCTUnwrap(restarted.state.sharedDeletionReview)
        XCTAssertEqual(review.id, task.id)

        // The user checks Google Tasks and removes the saved task there before confirming.
        server.setValue([])
        await restarted.send(.confirmSharedDeletion(review))
        await restarted.finish()
        XCTAssertNil(restarted.state.sharedDeletionReview)
        XCTAssertTrue(try inbox.requests(scope: context.scope).isEmpty)
    }

    func testFailedCancellationWriteKeepsRowUntilIntentCanBePersisted() async throws {
        let (inbox, state, writeID, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let fails = LockIsolated(true)
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.shareInbox = client(inbox)
            $0.shareInbox.requestDeletion = { ids, inFlight in
                if fails.value { throw AppFailure("Disk full") }
                try inbox.requestDeletion(taskIDs: ids, inFlightTaskIDs: inFlight)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.swipeDelete(task.id))
        XCTAssertEqual(store.state.snapshot.tasks, [task])
        XCTAssertEqual(store.state.pending.count, 1)
        XCTAssertEqual(try inbox.requests(scope: context.scope).first?.deletionRequested, false)

        fails.setValue(false)
        await store.send(.swipeDelete(task.id))
        await store.receive(\.checkSharedTasks)
        await store.send(.writeFinished(writeID, .failure(AppFailure("Unknown outcome"))))
        await store.receive(\.checkSharedTasks)
        await store.finish()
        XCTAssertTrue(store.state.snapshot.tasks.isEmpty)
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertEqual(store.state.sharedDeletionReview?.id, task.id)
    }

    func testFailedEditOfDeletedRemoteTaskStillDeletesServerBeforeRemovingReceipt() async throws {
        let (inbox, state, writeID, task) = try fixture(remoteID: "server-id")
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let operations = LockIsolated<[String]>([])
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.shareInbox = client(inbox)
            $0.shareInbox.remove = { ids in
                operations.withValue { $0.append("remove") }
                try inbox.remove(taskIDs: ids)
            }
            $0.taskClient.delete = { task in
                XCTAssertEqual(try inbox.requests(scope: "google:test@example.com").first?.deletionRequested, true)
                operations.withValue { $0.append("delete:\(task.remoteID ?? "missing")") }
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.swipeDelete(task.id))
        await store.receive(\.checkSharedTasks)
        await store.send(.writeFinished(writeID, .failure(AppFailure("Update failed"))))
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertEqual(operations.value, ["delete:server-id", "remove"])
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertTrue(try inbox.requests(scope: context.scope).isEmpty)
    }

    func testRestartResumesSavedDeletionEvenIfListNoLongerExists() async throws {
        let (inbox, _, _, task) = try fixture(remoteID: "server-id")
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        try inbox.requestDeletion(taskIDs: [task.id], inFlightTaskIDs: [])
        var state = AppFeature.State()
        state.account = "test@example.com"
        state.hasLoadedTasks = true
        let deleted = LockIsolated<[String]>([])
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.shareInbox = client(inbox)
            $0.taskClient.save = { task, _, _ in XCTFail("Recovery must delete, never insert")
                return task
            }
            $0.taskClient.delete = { task in deleted.withValue { $0.append(task.remoteID ?? "missing") } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.checkSharedTasks)
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertEqual(deleted.value, ["server-id"])
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertTrue(try inbox.requests(scope: context.scope).isEmpty)
    }

    func testLateReceiptDuringManualReviewIsDeletedInsteadOfDiscarded() async throws {
        let (inbox, initialState, _, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        try inbox.requestDeletion(taskIDs: [task.id], inFlightTaskIDs: [])
        var state = initialState
        state.pending = []
        state.isSaving = false
        state.snapshot.tasks = []
        let deleted = LockIsolated<[String]>([])
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.shareInbox = client(inbox)
            $0.taskClient.delete = { task in deleted.withValue { $0.append(task.remoteID ?? "missing") } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.checkSharedTasks)
        let review = try XCTUnwrap(store.state.sharedDeletionReview)
        try inbox.markSaved(taskID: task.id, remoteID: "late-id")
        await store.send(.confirmSharedDeletion(review))
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertEqual(deleted.value, ["late-id"])
        XCTAssertNil(store.state.sharedDeletionReview)
        XCTAssertTrue(try inbox.requests(scope: context.scope).isEmpty)
    }

    func testRestartedParentDeletionAlsoRemovesDescendantsAndTheirNotifications() async throws {
        let (inbox, initialState, _, task) = try fixture(remoteID: "server-id")
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        try inbox.requestDeletion(taskIDs: [task.id], inFlightTaskIDs: [])
        var state = initialState
        state.pending = []
        state.isSaving = false
        let day = TaskDay("2030-10-01")!
        let child = ReminderTask(
            id: "child",
            remoteID: "child",
            listID: "work",
            title: "Child",
            due: day,
            parentID: task.id,
        )
        state.snapshot.tasks.append(child)
        state.pendingNotificationEdits[child.id] = TaskNotificationEdit(date: day.date, enabled: true)
        state.notifications.isLoaded = true
        state.notifications.preferences.enabled = true
        let requests = LockIsolated<[ScheduledTaskNotification]>([])
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.shareInbox = client(inbox)
            $0.taskClient.delete = { _ in }
            $0.date.now = Date(timeIntervalSince1970: 0)
            $0.notifications.saveAndSchedule = { _, scheduled in
                requests.setValue(scheduled)
                return NotificationReport(access: .authorized)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.checkSharedTasks)
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertTrue(store.state.snapshot.tasks.isEmpty)
        XCTAssertTrue(store.state.pendingNotificationEdits.isEmpty)
        XCTAssertTrue(requests.value.isEmpty)
    }
}
