import ComposableArchitecture
import GoogleAPIClientForREST_Tasks
@testable import GreminderKit
import XCTest

@MainActor
final class AppFeatureTests: XCTestCase {
    func testCancelledAIRequestDoesNotShowErrorOrProposal() async {
        var state = AppFeature.State()
        state.snapshot = .sample()
        state.aiText = "Add a task"
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.localAI.propose = { _, _, _ in
                try await Task.sleep(for: .seconds(3600))
                return []
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.askAI)
        await store.send(.cancelProposal)
        await store.finish()
        XCTAssertFalse(store.state.isThinking)
        XCTAssertTrue(store.state.proposals.isEmpty)
        XCTAssertNil(store.state.error)
    }

    func testHomeSearchFindsOtherListsAndCompletedTasksWithoutFilteringSelectedList() {
        var state = AppFeature.State()
        state.selection = .list("work")
        state.snapshot.tasks = [
            ReminderTask(id: "1", listID: "work", title: "Work"),
            ReminderTask(id: "2", listID: "personal", title: "Coffee"),
            ReminderTask(id: "3", listID: "personal", title: "Finished", notes: "coffee beans", isCompleted: true),
        ]
        state.search = " coffee "
        XCTAssertEqual(state.searchResults.map(\.id), ["2", "3"])
        XCTAssertEqual(state.visibleTasks.map(\.id), ["1"])
        state.search = "   "
        XCTAssertTrue(state.searchResults.isEmpty)
    }

    func testHomeSearchResultOpensItsListAndDetails() async throws {
        let server = try TasksTestBlockServer()
        let store = makeStore(server: server)
        let task = try XCTUnwrap(server.snapshot.tasks.first { $0.listID == "personal" })
        await store.send(.openSearchResult(task.id))
        await store.finish()
        XCTAssertEqual(store.state.selection, .list(task.listID))
        XCTAssertEqual(store.state.compactColumn, .detail)
        XCTAssertEqual(store.state.editor?.task.id, task.id)
        XCTAssertTrue(store.state.showsTaskDetails)
    }

    private func makeStore(server: TasksTestBlockServer) -> TestStoreOf<AppFeature> {
        let service = GTLRTasksService()
        server.attach(to: service)
        let client = GoogleTasksService(service: service)
        var state = AppFeature.State()
        state.snapshot = server.snapshot
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.taskClient.save = { try await client.save($0, previousRemoteID: $1, parentRemoteID: $2) }
            $0.taskClient.delete = { try await client.delete($0) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    func testReturnCommitsAndContinuesThenEmptyReturnEndsWithoutEmptyTask() async throws {
        let server = try TasksTestBlockServer()
        let store = makeStore(server: server)
        await store.send(.beginAdd(after: nil, parent: nil))
        let firstID = try XCTUnwrap(store.state.editor?.task.id)
        await store.send(.editorTitle("最初のタスク"))
        await store.send(.commitEditor(continueAdding: true))
        XCTAssertEqual(store.state.editor?.afterID, firstID)
        XCTAssertEqual(store.state.editor?.task.title, "")
        await store.send(.editorTitle("次のタスク"))
        await store.send(.commitEditor(continueAdding: true))
        await store.send(.commitEditor(continueAdding: true))
        await store.finish()
        XCTAssertNil(store.state.editor)
        XCTAssertEqual(store.state.snapshot.tasks.count, 12)
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertEqual(server.requestedQueries.count(where: { $0.contains("TasksInsert") }), 2)
        let first = try XCTUnwrap(server.snapshot.tasks.firstIndex { $0.title == "最初のタスク" })
        XCTAssertEqual(server.snapshot.tasks[first + 1].title, "次のタスク")
    }

    func testEditingTitleReturnCreatesInputImmediatelyAfterEditedRow() async throws {
        let server = try TasksTestBlockServer()
        let store = makeStore(server: server)
        await store.send(.edit("sample-0"))
        await store.send(.editorTitle("修正したタイトル"))
        await store.send(.commitEditor(continueAdding: true))
        await store.finish()
        XCTAssertEqual(store.state.editor?.afterID, "sample-0")
        XCTAssertTrue(store.state.editor?.isNew == true)
        XCTAssertEqual(server.snapshot.tasks.first { $0.id == "sample-0" }?.title, "修正したタイトル")
        XCTAssertEqual(server.requestedQueries.count(where: { $0.contains("TasksPatch") }), 1)
        XCTAssertEqual(server.snapshot.tasks.count, 10)
    }

    func testSaveFailureRetainsInputAndQueuedWorkThenRetrySucceeds() async throws {
        let server = try TasksTestBlockServer()
        server.failNextRequest = AppFailure("保存できません")
        let store = makeStore(server: server)
        await store.send(.beginAdd(after: nil, parent: nil))
        await store.send(.editorTitle("消えてはいけない入力"))
        await store.send(.commitEditor(continueAdding: true))
        await store.receive(\.processQueue)
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertTrue(store.state.writeFailed)
        XCTAssertEqual(store.state.pending.count, 1)
        XCTAssertTrue(store.state.snapshot.tasks.contains { $0.title == "消えてはいけない入力" })
        XCTAssertNotNil(store.state.editor)
        await store.send(.retryWrites)
        await store.receive(\.processQueue)
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertFalse(store.state.writeFailed)
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertEqual(server.snapshot.tasks.count(where: { $0.title == "消えてはいけない入力" }), 1)
    }

    func testAIExampleUsesInsertQueriesAndPreservesParentChildRelationship() async throws {
        for language in [DisplayLanguage.japanese, .english] {
            let defaults = UserDefaults.inMemory
            defaults.set(language.rawValue, forKey: L10n.preferenceKey)
            try await withDependencies {
                $0.defaultAppStorage = defaults
            } operation: {
                let server = try TasksTestBlockServer()
                let store = makeStore(server: server)
                await store.send(.showExample)
                XCTAssertEqual(store.state.proposedCount, 3)
                XCTAssertTrue(store.state.isExample)
                let proposal = try XCTUnwrap(store.state.proposals.first)
                await store.send(.applyProposal)
                await store.finish()
                XCTAssertEqual(server.requestedQueries.count(where: { $0.contains("TasksInsert") }), 3)
                let parent = try XCTUnwrap(server.snapshot.tasks.first { $0.title == proposal.task.title })
                XCTAssertEqual(
                    server.snapshot.tasks.filter { $0.parentID == parent.id }.map(\.title),
                    proposal.subtasks,
                )
                XCTAssertTrue(store.state.proposals.isEmpty)
            }
        }
    }

    func testStaleAIProposalIsNotAppliedAfterTaskChanges() async throws {
        let server = try TasksTestBlockServer()
        let store = makeStore(server: server)
        await store.send(.showExample)
        await store.send(.toggleComplete("sample-0"))
        await store.finish()
        await store.send(.applyProposal)
        XCTAssertNotNil(store.state.error)
        XCTAssertTrue(store.state.proposals.isEmpty)
        XCTAssertFalse(server.requestedQueries.contains { $0.contains("TasksInsert") })
    }

    func testDetailsCommitThroughSDKAndKeepSelectionOnFieldSave() async throws {
        let server = try TasksTestBlockServer()
        let store = makeStore(server: server)
        await store.send(.openDetails("sample-0"))
        let editorID = store.state.editor?.id
        await store.send(.editorTitle("詳細で変更したタイトル"))
        await store.send(.editorNotes("複数行のメモ\n次の行"))
        await store.send(.editorSchedule("sample-0", .date(nil)))
        await store.send(.saveDetails("sample-0"))
        await store.finish()
        XCTAssertTrue(store.state.showsTaskDetails)
        XCTAssertEqual(store.state.editor?.id, editorID)
        XCTAssertNil(server.snapshot.tasks.first { $0.id == "sample-0" }?.due)
        await store.send(.closeDetails)
        await store.finish()
        XCTAssertNil(store.state.editor)
        XCTAssertFalse(store.state.showsTaskDetails)
        XCTAssertEqual(server.snapshot.tasks.first { $0.id == "sample-0" }?.notes, "複数行のメモ\n次の行")
        XCTAssertEqual(server.requestedQueries.count(where: { $0.contains("TasksPatch") }), 1)
    }

    func testDetailsSelectionCommitsPreviousAndIgnoresLateFocusEvent() async throws {
        let server = try TasksTestBlockServer()
        let store = makeStore(server: server)
        await store.send(.edit("sample-0"))
        await store.send(.editorTitle("インラインの続き"))
        await store.send(.openDetails("sample-0"))
        XCTAssertEqual(store.state.editor?.task.title, "インラインの続き")
        await store.send(.edit("sample-1"))
        await store.send(.editorNotes("新しい選択の未確定メモ"))
        await store.send(.saveDetails("sample-0"))
        await store.finish()
        XCTAssertTrue(store.state.showsTaskDetails)
        XCTAssertEqual(store.state.editor?.task.id, "sample-1")
        XCTAssertEqual(store.state.editor?.task.notes, "新しい選択の未確定メモ")
        XCTAssertEqual(server.snapshot.tasks.first { $0.id == "sample-0" }?.title, "インラインの続き")
        XCTAssertNotEqual(server.snapshot.tasks.first { $0.id == "sample-1" }?.notes, "新しい選択の未確定メモ")
        await store.send(.closeDetails)
        await store.finish()
    }

    func testInvalidDetailCannotBeDismissedOrSwitchedAndCanBeCorrected() async throws {
        let server = try TasksTestBlockServer()
        let store = makeStore(server: server)
        await store.send(.openDetails("sample-0"))
        await store.send(.editorTitle(" "))
        await store.send(.closeDetails)
        await store.send(.openDetails("sample-1"))
        await store.send(.select(.all))
        await store.send(.toggleComplete("sample-0"))
        await store.finish()
        XCTAssertTrue(store.state.showsTaskDetails)
        XCTAssertEqual(store.state.editor?.task.id, "sample-0")
        XCTAssertEqual(store.state.editor?.task.title, " ")
        XCTAssertEqual(store.state.selection, .today)
        XCTAssertNotNil(store.state.error)
        XCTAssertTrue(server.requestedQueries.isEmpty)
        await store.send(.editorTitle("修正したタスク"))
        await store.send(.closeDetails)
        await store.finish()
        XCTAssertFalse(store.state.showsTaskDetails)
        XCTAssertNil(store.state.error)
        XCTAssertEqual(server.snapshot.tasks.first { $0.id == "sample-0" }?.title, "修正したタスク")
    }

    func testDetailsCompletionKeepsPanelAndDeleteClosesIt() async throws {
        let server = try TasksTestBlockServer()
        let store = makeStore(server: server)
        await store.send(.openDetails("sample-0"))
        await store.send(.editorNotes("完了する前の変更"))
        await store.send(.toggleComplete("sample-0"))
        await store.finish()
        XCTAssertTrue(store.state.showsTaskDetails)
        XCTAssertEqual(store.state.editor?.task.isCompleted, true)
        XCTAssertEqual(server.snapshot.tasks.first { $0.id == "sample-0" }?.notes, "完了する前の変更")
        await store.send(.requestDelete("sample-0"))
        await store.send(.confirmDelete)
        await store.finish()
        XCTAssertFalse(store.state.showsTaskDetails)
        XCTAssertNil(store.state.editor)
        XCTAssertFalse(server.snapshot.tasks.contains { $0.id == "sample-0" })
    }

    func testDetailSaveFailureRetainsEditedContentAndRetryWorks() async throws {
        let server = try TasksTestBlockServer()
        server.failNextRequest = AppFailure("通信エラー")
        let store = makeStore(server: server)
        await store.send(.openDetails("sample-0"))
        await store.send(.editorNotes("保存失敗しても保持するメモ"))
        await store.send(.saveDetails("sample-0"))
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertTrue(store.state.writeFailed)
        XCTAssertEqual(store.state.editor?.task.notes, "保存失敗しても保持するメモ")
        await store.send(.retryWrites)
        await store.receive(\.writeFinished)
        await store.finish()
        XCTAssertTrue(store.state.showsTaskDetails)
        XCTAssertFalse(store.state.writeFailed)
        XCTAssertEqual(server.snapshot.tasks.first { $0.id == "sample-0" }?.notes, "保存失敗しても保持するメモ")
    }
}
