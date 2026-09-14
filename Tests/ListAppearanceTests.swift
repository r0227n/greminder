import ComposableArchitecture
import GoogleAPIClientForREST_Tasks
@testable import GreminderKit
import XCTest

@MainActor
final class ListAppearanceTests: XCTestCase {
    func testMultipleStoresMergeLatestPersistedValuesInsteadOfOverwritingOtherLists() throws {
        let suite = "greminder.appearance.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ListAppearanceStore(defaults: defaults)
        let second = ListAppearanceStore(defaults: defaults)
        let one = ListAppearance(symbol: "star.fill", tint: "orange")
        let two = ListAppearance(symbol: "book.fill", tint: "purple")
        first.save(one, account: "A", listID: "1")
        second.save(two, account: "B", listID: "2")
        XCTAssertEqual(first.appearance(account: "B", listID: "2"), two)
        XCTAssertEqual(second.appearance(account: "A", listID: "1"), one)
        let fresh = ListAppearanceStore(defaults: defaults)
        XCTAssertEqual(fresh.appearance(account: "A", listID: "1"), one)
        XCTAssertEqual(fresh.appearance(account: "B", listID: "2"), two)
    }

    func testSuggestedAppearanceIsStableAcrossPaginationRenameAndReordering() async throws {
        let snapshot = TaskSnapshot(lists: (0 ..< 5).map { TaskList(id: "list-\($0)", title: "List \($0)") })
        let paged = try TasksTestBlockServer(snapshot: snapshot, pageSize: 2)
        let service = GTLRTasksService()
        paged.attach(to: service)
        let appearances = ListAppearanceStore()
        let client = GoogleTasksService(service: service, appearances: appearances)
        let original = try await client.load()
        XCTAssertEqual(original.lists.map(\.tint), ["blue", "red", "green", "blue", "red"])
        paged.snapshot.lists.reverse()
        paged.snapshot.lists[0].title = "Shopping"
        let reloaded = try await client.load()
        for list in reloaded.lists {
            let before = try XCTUnwrap(original.lists.first { $0.id == list.id })
            XCTAssertEqual(list.symbol, before.symbol)
            XCTAssertEqual(list.tint, before.tint)
        }
    }

    func testSDKCreationAndReloadPreserveAppearanceAndIsolateAccounts() async throws {
        let suite = "greminder.appearance.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = try TasksTestBlockServer()
        let service = GTLRTasksService()
        server.attach(to: service)
        let client = GoogleTasksService(
            service: service,
            appearances: ListAppearanceStore(defaults: defaults),
            accountKey: "A",
        )
        let style = ListAppearance(symbol: "star.fill", tint: "purple")
        let created = try await client.addList("日本語 / English", appearance: style)
        XCTAssertEqual(created.symbol, style.symbol)
        XCTAssertEqual(created.tint, style.tint)
        let reloaded = GoogleTasksService(
            service: service,
            appearances: ListAppearanceStore(defaults: defaults),
            accountKey: "A",
        )
        let snapshot = try await reloaded.load()
        XCTAssertEqual(snapshot.lists.first { $0.id == created.id }, created)
        let storage = ListAppearanceStore(defaults: defaults)
        XCTAssertNil(storage.appearance(account: "B", listID: created.id))
        XCTAssertNil(storage.appearance(account: "sample", listID: created.id))
        XCTAssertEqual(server.requestedQueries.count(where: { $0.contains("TasklistsInsert") }), 1)
    }

    func testFailedCreationKeepsAppearanceForRetry() async throws {
        let server = try TasksTestBlockServer()
        let service = GTLRTasksService()
        server.attach(to: service)
        let client = GoogleTasksService(service: service)
        var state = AppFeature.State()
        state.newListTitle = "Travel"
        state.newListAppearance = ListAppearance(symbol: "airplane", tint: "orange")
        state.showsNewList = true
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.taskClient.addList = { try await client.addList($0, appearance: $1) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        server.failNextRequest = AppFailure("offline")
        await store.send(.addList)
        await store.receive(\.listAdded)
        await store.finish()
        XCTAssertTrue(store.state.showsNewList)
        XCTAssertEqual(store.state.newListAppearance, state.newListAppearance)
        await store.send(.addList)
        await store.receive(\.listAdded)
        await store.finish()
        XCTAssertFalse(store.state.showsNewList)
        XCTAssertEqual(store.state.snapshot.lists.last?.symbol, "airplane")
        XCTAssertEqual(store.state.snapshot.lists.last?.tint, "orange")
        XCTAssertEqual(store.state.newListAppearance, ListAppearance())
    }

    func testUnknownStoredAppearanceFallsBackToSupportedChoices() {
        XCTAssertEqual(ListAppearance(symbol: "missing", tint: "missing").validated, ListAppearance())
    }
}
