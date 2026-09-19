import Foundation
import GoogleAPIClientForREST_Tasks
@testable import GreminderKit
import Testing

@Suite("Google Tasks削除の再試行")
@MainActor
struct GoogleTasksDeletionTests {
    @Test("削除済みタスクの再削除を成功として扱う")
    func retryAfterRemoteDeletionSucceeds() async throws {
        let server = try TasksTestBlockServer()
        let service = GTLRTasksService()
        server.attach(to: service)
        let client = GoogleTasksService(service: service)
        let task = try #require(server.snapshot.tasks.first)
        try await client.delete(task)
        #expect(!server.snapshot.tasks.contains { $0.id == task.id })
        try await client.delete(task)
        #expect(server.requestedQueries.count { $0.contains("TasksDelete") } == 2)
    }

    @Test("構造化応答と本文なしのHTTP 404を受け入れる", arguments: [
        kGTLRErrorObjectDomain, kGTMSessionFetcherStatusDomain,
    ])
    func acceptsSDKNotFound(domain: String) async throws {
        try await client(failingWith: NSError(domain: domain, code: 404)).delete(task)
    }

    @Test("認証、権限、競合、サーバーエラーは握りつぶさない", arguments: [
        kGTLRErrorObjectDomain, kGTMSessionFetcherStatusDomain,
    ], [401, 403, 412, 500])
    func preservesOtherHTTPErrors(domain: String, status: Int) async {
        let failure = NSError(domain: domain, code: status)
        do {
            try await client(failingWith: failure).delete(task)
            Issue.record("Expected the original HTTP failure")
        } catch {
            #expect((error as NSError).domain == domain)
            #expect((error as NSError).code == status)
        }
    }

    @Test("別ドメインの404はHTTP Not Foundとして扱わない", arguments: [NSURLErrorDomain, NSCocoaErrorDomain])
    func preservesUnrelatedErrorWithSameCode(domain: String) async {
        do {
            try await client(failingWith: NSError(domain: domain, code: 404)).delete(task)
            Issue.record("Expected the non-HTTP failure")
        } catch {
            #expect((error as NSError).domain == domain)
            #expect((error as NSError).code == 404)
        }
    }

    private var task: ReminderTask {
        ReminderTask(id: "local", remoteID: "remote", listID: "list", title: "Task", etag: "original-etag")
    }

    private func client(failingWith error: NSError) -> GoogleTasksService {
        let service = GTLRTasksService()
        service.testBlock = { ticket, response in
            #expect(ticket.originalQuery is GTLRTasksQuery_TasksDelete)
            response(nil, error)
        }
        return GoogleTasksService(service: service)
    }
}
