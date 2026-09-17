import GoogleAPIClientForREST_Tasks
@testable import GreminderKit
import XCTest

@MainActor
final class GoogleTasksServiceTests: XCTestCase {
    func testFailedAccountSwitchPreservesActiveTransportAndAccount() async throws {
        let demoServer = try TasksTestBlockServer()
        let accountServer = try TasksTestBlockServer()
        let demo = makeClient(server: demoServer)
        let account = makeClient(server: accountServer)
        var signOutCount = 0
        let environment = TasksEnvironment(
            demo: demo,
            signIn: { TasksAccountConnection(client: account, account: "user@example.com") },
            signOut: { signOutCount += 1 },
        )
        _ = try await environment.load()
        accountServer.failNextRequest = AppFailure("offline")
        do {
            _ = try await environment.connect()
            XCTFail("An offline destination must not replace the active transport")
        } catch { XCTAssertEqual(error.localizedDescription, "offline") }
        XCTAssertTrue(environment.client === demo)
        let unchanged = try await environment.load()
        XCTAssertNil(unchanged.account)
        let connected = try await environment.connect()
        XCTAssertEqual(connected.account, "user@example.com")
        XCTAssertTrue(environment.client === account)

        // Signing out in real API mode must not issue fallback requests to the mock server.
        demoServer.failNextRequest = AppFailure("sample unavailable")
        let disconnected = try await environment.disconnect()
        XCTAssertNil(disconnected.account)
        XCTAssertTrue(disconnected.snapshot.tasks.isEmpty)
        XCTAssertTrue(demoServer.requestedQueries.isEmpty)
        XCTAssertEqual(signOutCount, 1)
        XCTAssertTrue(environment.client === demo)
    }

    func testFailedRestorationIsRetriedAndDamagedSampleDoesNotBlockGoogleAccount() async throws {
        let server = try TasksTestBlockServer()
        let remote = makeClient(server: server)
        let demo = try makeClient(server: TasksTestBlockServer())
        var restoreCount = 0
        let connection = TasksAccountConnection(client: remote, account: "restored@example.com")
        let environment = TasksEnvironment(
            demo: demo,
            initializationError: AppFailure("damaged sample file"),
            restoreAccount: {
                restoreCount += 1
                if restoreCount == 1 { throw AppFailure("offline") }
                return connection
            },
            signIn: { connection },
        )
        do {
            _ = try await environment.load()
            XCTFail("Expected the initial restoration failure")
        } catch { XCTAssertEqual(error.localizedDescription, "offline") }
        XCTAssertTrue(environment.client === demo)
        let restored = try await environment.load()
        XCTAssertEqual(restored.account, connection.account)
        XCTAssertEqual(restoreCount, 2)
        XCTAssertTrue(environment.client === remote)
        _ = try await environment.load()
        XCTAssertEqual(restoreCount, 2)
    }

    func testChildInsertWithoutSavedParentDoesNotSendRequest() async throws {
        let server = try TasksTestBlockServer()
        let client = makeClient(server: server)
        do {
            _ = try await client.save(
                ReminderTask(id: "child", listID: "work", title: "Child", parentID: "unsaved-parent"),
                previousRemoteID: nil,
                parentRemoteID: nil,
            )
            XCTFail("An unresolved parent must not silently create a root task")
        } catch { XCTAssertTrue(error is AppFailure) }
        XCTAssertTrue(server.requestedQueries.isEmpty)
    }

    private func makeClient(server: TasksTestBlockServer) -> GoogleTasksService {
        let service = GTLRTasksService()
        server.attach(to: service)
        return GoogleTasksService(service: service)
    }

    func testPaginationUsesActualSDKQueriesAndIncludesCompletedTasks() async throws {
        let server = try TasksTestBlockServer(pageSize: 2)
        let service = GTLRTasksService()
        server.attach(to: service)
        let client = GoogleTasksService(service: service)
        let snapshot = try await client.load()
        XCTAssertEqual(snapshot.lists.count, 3)
        XCTAssertEqual(snapshot.tasks.count, 10)
        XCTAssertEqual(snapshot.tasks.filter(\.isCompleted).count, 3)
        XCTAssertEqual(server.requestedQueries.count(where: { $0.contains("TasklistsList") }), 2)
        XCTAssertGreaterThan(server.requestedQueries.count(where: { $0.contains("TasksList") }), 3)
    }

    func testInsertParentChildPatchClearDateAndDeleteViaTestBlock() async throws {
        let server = try TasksTestBlockServer()
        let service = GTLRTasksService()
        server.attach(to: service)
        let client = GoogleTasksService(service: service)
        var parent = ReminderTask(id: "local-parent", listID: "work", title: "親タスク", due: TaskDay("2026-09-14"))
        parent = try await client.save(parent, previousRemoteID: "sample-0", parentRemoteID: nil)
        XCTAssertEqual(parent.id, "local-parent")
        XCTAssertNotNil(parent.remoteID)
        let child = ReminderTask(id: "local-child", listID: "work", title: "子タスク", parentID: parent.id)
        let savedChild = try await client.save(child, previousRemoteID: nil, parentRemoteID: parent.remoteID)
        XCTAssertEqual(server.snapshot.tasks.first { $0.id == savedChild.remoteID }?.parentID, parent.remoteID)
        parent.due = nil
        parent.isCompleted = true
        parent.title = "更新した親タスク"
        let updated = try await client.save(parent, previousRemoteID: nil, parentRemoteID: nil)
        XCTAssertNil(updated.due)
        XCTAssertTrue(updated.isCompleted)
        XCTAssertEqual(updated.title, "更新した親タスク")
        try await client.delete(updated)
        XCTAssertFalse(server.snapshot.tasks.contains { $0.id == parent.remoteID || $0.parentID == parent.remoteID })
        XCTAssertEqual(server.requestedQueries.count(where: { $0.contains("TasksInsert") }), 2)
        XCTAssertEqual(server.requestedQueries.count(where: { $0.contains("TasksPatch") }), 1)
        XCTAssertEqual(server.requestedQueries.count(where: { $0.contains("TasksDelete") }), 1)
    }

    func testPatchSendsExplicitNullToClearDateAndConditionalHeader() async throws {
        let service = GTLRTasksService()
        service.testBlock = { ticket, response in
            guard let query = ticket.originalQuery as? GTLRTasksQuery_TasksPatch,
                  let body = query.bodyObject as? GTLRTasks_Task
            else {
                XCTFail("Expected a TasksPatch query with a Tasks body")
                response(nil, AppFailure("Unexpected SDK query") as NSError)
                return
            }
            XCTAssertTrue(body.jsonValue(forKey: "due") is NSNull)
            XCTAssertEqual(query.additionalHTTPHeaders?["If-Match"], "known-etag")
            let result = GTLRTasks_Task()
            result.identifier = "remote-1"
            result.title = "編集"
            response(result, nil)
        }
        let client = GoogleTasksService(service: service)
        _ = try await client.save(
            ReminderTask(id: "1", remoteID: "remote-1", listID: "work", title: "編集", etag: "known-etag"),
            previousRemoteID: nil,
            parentRemoteID: nil,
        )
    }

    func testTestBlockRejectsStalePatchAndDeleteWithoutChangingSnapshot() async throws {
        let server = try TasksTestBlockServer()
        let client = makeClient(server: server)
        let snapshot = try await client.load()
        var stale = try XCTUnwrap(snapshot.tasks.first)
        stale.title = "First writer"
        let saved = try await client.save(stale, previousRemoteID: nil, parentRemoteID: nil)
        XCTAssertNotEqual(saved.etag, stale.etag)
        let committed = server.snapshot
        stale.title = "Stale writer"
        do {
            _ = try await client.save(stale, previousRemoteID: nil, parentRemoteID: nil)
            XCTFail("A stale update must fail its If-Match precondition")
        } catch { XCTAssertEqual((error as NSError).code, 412) }
        XCTAssertEqual(server.snapshot, committed)
        do {
            try await client.delete(stale)
            XCTFail("A stale delete must fail its If-Match precondition")
        } catch { XCTAssertEqual((error as NSError).code, 412) }
        XCTAssertEqual(server.snapshot, committed)
    }

    func testTestBlockPartialPatchPreservesOmittedFields() throws {
        let day = try XCTUnwrap(TaskDay("2026-09-14"))
        let task = ReminderTask(
            id: "1", remoteID: "1", listID: "work", title: "Original", notes: "Notes",
            due: day, isCompleted: true,
        )
        let server = try TasksTestBlockServer(snapshot: TaskSnapshot(
            lists: [TaskList(id: "work", title: "Work")], tasks: [task],
        ))
        let body = GTLRTasks_Task()
        body.title = "Renamed"
        let query = GTLRTasksQuery_TasksPatch.query(withObject: body, tasklist: "work", task: "1")
        _ = try server.respond(to: query)
        XCTAssertEqual(server.snapshot.tasks[0].title, "Renamed")
        XCTAssertEqual(server.snapshot.tasks[0].notes, "Notes")
        XCTAssertEqual(server.snapshot.tasks[0].due, day)
        XCTAssertTrue(server.snapshot.tasks[0].isCompleted)
    }

    func testCalendarDayDoesNotShiftAcrossTimeZones() {
        let day = TaskDay("2026-09-13")!
        XCTAssertEqual(day.apiValue, "2026-09-13T00:00:00.000Z")
        XCTAssertNil(TaskDay("2026-02-30"))
        XCTAssertNil(TaskDay("2026-9-3"))
        XCTAssertTrue(day < TaskDay("2026-09-14")!)
    }
}
