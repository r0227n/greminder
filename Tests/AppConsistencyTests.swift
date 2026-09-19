import ComposableArchitecture
@testable import GreminderKit
import XCTest

@MainActor
final class AppConsistencyTests: XCTestCase {
    func testExistingBlankInlineDraftCannotBeSilentlyDiscarded() async {
        var state = AppFeature.State()
        state.snapshot = .sample()
        let store = store(state)
        await store.send(.edit("sample-0"))
        await store.send(.editorTitle(""))
        await store.send(.editorNotes("Keep these notes"))
        await store.send(.select(.all))
        XCTAssertEqual(store.state.editor?.task.notes, "Keep these notes")
        XCTAssertEqual(store.state.selection, state.selection)
        XCTAssertNotNil(store.state.error)
    }

    func testInvalidScheduleEditDoesNotChangeNotificationOrSavedTask() async throws {
        var state = scheduleState()
        state.editor?.task.title = ""
        state.showsTaskDetails = true
        let original = state.notifications.preferences
        let store = store(state)
        await store.send(.editorSchedule("task", .date(TaskDay("2026-09-20"))))
        await store.send(.editorSchedule("task", .enabled(false)))
        await store.finish()
        XCTAssertEqual(store.state.notifications.preferences, original)
        XCTAssertEqual(store.state.snapshot, state.snapshot)
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertTrue(store.state.pendingNotificationEdits.isEmpty)
        XCTAssertNotNil(store.state.editor)
    }

    func testLocalRescheduleMovesOverdueNotificationOnlyAfterInlineCommit() async throws {
        let state = scheduleState()
        let store = store(state)
        store.dependencies.taskClient.save = { task, _, _ in task }
        let original = store.state.notifications.preferences
        let newDay = try XCTUnwrap(TaskDay("2026-09-20"))
        await store.send(.editorSchedule("task", .date(newDay)))
        await store.finish()
        XCTAssertEqual(store.state.notifications.preferences, original)
        XCTAssertEqual(store.state.editorNotificationDate.map { TaskDay(date: $0) }, newDay)
        await store.send(.commitEditor(continueAdding: false))
        await store.receive(\.processQueue)
        await store.receive(\.writeFinished)
        await store.finish()
        let task = try XCTUnwrap(store.state.snapshot.tasks.first)
        let record = try XCTUnwrap(store.state.notifications.record(for: task))
        XCTAssertEqual(TaskDay(date: record.date), newDay)
        XCTAssertEqual(Calendar.current.component(.hour, from: record.date), 10)
        XCTAssertFalse(record.isEnabled)
    }

    private func scheduleState() -> AppFeature.State {
        let due = TaskDay("2026-09-01")!
        let task = ReminderTask(id: "task", remoteID: "remote", listID: "work", title: "Task", due: due)
        var state = AppFeature.State()
        state.snapshot = TaskSnapshot(lists: [TaskList(id: "work", title: "Work")], tasks: [task])
        state.editor = TaskEditor(id: "editor", task: task, isNew: false)
        state.notifications.isLoaded = true
        state.notifications.preferences.enabled = true
        let key = NotificationPlanner.key(task: task, scope: state.notifications.scope)
        state.notifications.preferences.records[key] = NotificationRecord(
            date: NotificationPlanner.date(day: due, hour: 10, minute: 15), sourceDay: due, isEnabled: false,
        )
        return state
    }

    private func store(_ state: AppFeature.State) -> TestStoreOf<AppFeature> {
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 1_800_000_000)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    func testReloadCannotBeOverwrittenByConcurrentLocalMutation() async {
        var state = AppFeature.State()
        state.snapshot = .sample()
        state.isLoading = true
        state.aiText = "Add task"
        let store = store(state)
        await store.send(.beginAdd(after: nil, parent: nil))
        await store.send(.edit("sample-0"))
        await store.send(.toggleComplete("sample-0"))
        await store.send(.requestDelete("sample-0"))
        await store.send(.askAI)
        await store.send(.openVoice(.task))
        XCTAssertEqual(store.state.snapshot, state.snapshot)
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertNil(store.state.editor)
        XCTAssertNil(store.state.deleteCandidate)
        XCTAssertNil(store.state.aiRequest)
        XCTAssertFalse(store.state.showsVoice)
    }

    func testChildAddedFromSmartListInheritsParentsList() async {
        var state = AppFeature.State()
        state.snapshot = .sample()
        state.selection = .all
        let store = store(state)
        await store.send(.beginAdd(after: "sample-2", parent: "sample-2"))
        await store.finish()
        XCTAssertEqual(store.state.editor?.task.listID, "personal")
        XCTAssertEqual(store.state.editor?.task.parentID, "sample-2")
    }

    func testDeletingParentPrunesUnsentChildrenAndPreservesInFlightIdentity() async {
        let parent = ReminderTask(id: "p", listID: "work", title: "Parent")
        let child = ReminderTask(id: "c", listID: "work", title: "Child", parentID: "p")
        var state = AppFeature.State()
        state.snapshot = TaskSnapshot(tasks: [parent, child])
        state.pending = [PendingWrite(task: parent), PendingWrite(task: child)]
        state.isSaving = true
        let insertID = state.pending[0].id
        let deleted = LockIsolated<ReminderTask?>(nil)
        let store = store(state)
        store.dependencies.taskClient.delete = { deleted.setValue($0) }
        await store.send(.requestDelete("p"))
        await store.send(.confirmDelete)
        await store.finish()
        XCTAssertEqual(store.state.pending.map(\.task.id), ["p", "p"])
        XCTAssertTrue(store.state.snapshot.tasks.isEmpty)
        var saved = parent
        saved.remoteID = "google-p"
        await store.send(.writeFinished(insertID, .success(saved)))
        await store.receive(\.processQueue)
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertEqual(deleted.value?.remoteID, "google-p")
        XCTAssertTrue(store.state.pending.isEmpty)
    }

    func testFailedInFlightChildIsNotRetriedAfterParentWasDeleted() async {
        let parent = ReminderTask(id: "p", remoteID: "google-p", listID: "work", title: "Parent")
        let child = ReminderTask(id: "c", listID: "work", title: "Child", parentID: "p")
        var state = AppFeature.State()
        state.snapshot = TaskSnapshot(tasks: [parent, child])
        state.pending = [PendingWrite(task: child)]
        state.isSaving = true
        let insertID = state.pending[0].id
        let store = store(state)
        store.dependencies.taskClient.delete = { _ in }
        await store.send(.requestDelete("p"))
        await store.send(.confirmDelete)
        await store.finish()
        await store.send(.writeFinished(insertID, .failure(AppFailure("Cancelled target"))))
        await store.receive(\.processQueue)
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertFalse(store.state.writeFailed)
    }

    func testSwipeDeleteImmediatelyRemovesParentAndChildrenAndClosesTheirEditor() async {
        let parent = ReminderTask(id: "p", remoteID: "google-p", listID: "work", title: "Parent")
        let child = ReminderTask(id: "c", remoteID: "google-c", listID: "work", title: "Child", parentID: "p")
        let other = ReminderTask(id: "other", listID: "work", title: "Keep")
        var state = AppFeature.State()
        state.snapshot = TaskSnapshot(tasks: [parent, child, other])
        state.editor = TaskEditor(id: "editor", task: child, isNew: false)
        state.showsTaskDetails = true
        let deleted = LockIsolated<[String]>([])
        let store = store(state)
        store.dependencies.taskClient.delete = { task in deleted.withValue { $0.append(task.id) } }

        await store.send(.swipeDelete("p"))
        XCTAssertEqual(store.state.snapshot.tasks, [other])
        XCTAssertNil(store.state.deleteCandidate)
        XCTAssertNil(store.state.editor)
        XCTAssertFalse(store.state.showsTaskDetails)
        await store.receive(\.processQueue)
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertEqual(deleted.value, ["p"])
        XCTAssertTrue(store.state.pending.isEmpty)
    }

    func testSwipeDeleteFailureKeepsDeletionQueuedForRetry() async {
        let task = ReminderTask(id: "task", remoteID: "remote", listID: "work", title: "Task")
        var state = AppFeature.State()
        state.snapshot = TaskSnapshot(tasks: [task])
        let store = store(state)
        store.dependencies.taskClient.delete = { _ in throw AppFailure("Offline") }

        await store.send(.swipeDelete(task.id))
        await store.receive(\.processQueue)
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertTrue(store.state.snapshot.tasks.isEmpty)
        XCTAssertTrue(store.state.writeFailed)
        XCTAssertEqual(store.state.pending.count, 1)
        XCTAssertTrue(store.state.pending.first?.isDelete == true)
        store.dependencies.taskClient.delete = { _ in }
        await store.send(.retryWrites)
        await store.receive(\.processQueue)
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertFalse(store.state.writeFailed)
    }

    func testSwipeDeleteIgnoresUnavailableOrStaleRows() async {
        for mode in 0 ..< 3 {
            var state = AppFeature.State()
            state.snapshot = .sample()
            state.isLoading = mode == 0
            state.showsVoice = mode == 1
            let store = store(state)
            await store.send(.swipeDelete(mode == 2 ? "missing" : "sample-0"))
            await store.finish()
            XCTAssertEqual(store.state.snapshot, state.snapshot)
            XCTAssertTrue(store.state.pending.isEmpty)
            XCTAssertNil(store.state.deleteCandidate)
        }
    }

    func testStaleAIResultCannotReplaceNewerRequest() async {
        var state = AppFeature.State()
        state.snapshot = .sample()
        let current = AIRequest(id: UUID(), context: AIContext(snapshot: state.snapshot, account: nil))
        state.aiRequest = current
        let store = store(state)
        await store.send(.aiResult(UUID(), .failure(AppFailure("stale"))))
        XCTAssertEqual(store.state.aiRequest, current)
        XCTAssertNil(store.state.error)
    }

    func testProposalCannotOverwriteAnUncommittedValidDraft() async throws {
        var state = AppFeature.State()
        state.snapshot = .sample()
        let original = try XCTUnwrap(state.snapshot.tasks.first)
        var proposed = original
        proposed.isCompleted = true
        state.proposalBatch = AIProposalBatch(
            context: AIContext(snapshot: state.snapshot, account: nil),
            proposals: [TaskProposal(operation: .complete, task: proposed)],
        )
        var draft = original
        draft.title = "Keep my edit"
        state.editor = TaskEditor(id: "editor", task: draft, isNew: false)
        let store = store(state)
        store.dependencies.taskClient.save = { task, _, _ in task }
        await store.send(.applyProposal)
        await store.finish()
        XCTAssertEqual(store.state.snapshot.tasks.first?.title, "Keep my edit")
        XCTAssertEqual(store.state.snapshot.tasks.first?.isCompleted, false)
        XCTAssertTrue(store.state.proposals.isEmpty)
    }

    func testInvalidDraftBlocksAIRequest() async {
        var state = AppFeature.State()
        state.snapshot = .sample()
        state.editor = TaskEditor(
            id: "editor",
            task: ReminderTask(id: "new", listID: "work", title: String(repeating: "x", count: 1025)),
            isNew: true,
        )
        state.aiText = "Add a task"
        let store = store(state)
        await store.send(.askAI)
        XCTAssertNil(store.state.aiRequest)
        XCTAssertNotNil(store.state.editor)
        XCTAssertNotNil(store.state.error)
    }
}
