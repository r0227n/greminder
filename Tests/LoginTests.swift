import ComposableArchitecture
import GoogleSignIn
@testable import GreminderKit
import XCTest

@MainActor
final class LoginTests: XCTestCase {
    func testSignedOutLaunchStaysOnLogin() async {
        let store = makeStore()
        await store.send(.reload)
        await store.receive(\.loaded)
        await store.finish()
        XCTAssertFalse(store.state.isSignedIn)
        XCTAssertFalse(store.state.isLoading)
    }

    func testSuccessfulSignInShowsHomeAndSignOutReturnsToLogin() async {
        let store = makeStore()
        await store.send(.connect)
        await store.receive(\.loaded)
        await store.finish()
        XCTAssertTrue(store.state.isSignedIn)
        XCTAssertEqual(store.state.account, "user@example.com")
        await store.send(.binding(.set(\.showsSettings, true)))
        await store.send(.disconnect)
        await store.receive(\.loaded)
        await store.finish()
        XCTAssertFalse(store.state.isSignedIn)
        XCTAssertFalse(store.state.showsSettings)
    }

    func testRestoredAccountShowsHome() async {
        let store = makeStore()
        store.dependencies.taskClient.load = {
            ConnectedTasks(snapshot: TaskSnapshot(), account: "restored@example.com")
        }
        await store.send(.reload)
        await store.receive(\.loaded)
        await store.finish()
        XCTAssertTrue(store.state.isSignedIn)
    }

    func testFailedSignInStaysOnLoginAndCanRetry() async {
        let store = makeStore()
        store.dependencies.taskClient.connect = { throw AppFailure("offline") }
        await store.send(.connect)
        await store.receive(\.loaded)
        await store.finish()
        XCTAssertFalse(store.state.isSignedIn)
        XCTAssertEqual(store.state.error, "offline")
        XCTAssertTrue(store.state.canSwitchAccount)
        store.dependencies.taskClient.connect = {
            ConnectedTasks(snapshot: TaskSnapshot(), account: "user@example.com")
        }
        await store.send(.connect)
        await store.receive(\.loaded)
        await store.finish()
        XCTAssertTrue(store.state.isSignedIn)
        XCTAssertNil(store.state.error)
    }

    func testCancelledSignInStaysOnLoginWithoutError() async {
        let store = makeStore()
        store.dependencies.taskClient.connect = {
            throw NSError(domain: kGIDSignInErrorDomain, code: GIDSignInError.canceled.rawValue)
        }
        await store.send(.connect)
        await store.receive(\.signInCancelled)
        await store.finish()
        XCTAssertFalse(store.state.isSignedIn)
        XCTAssertNil(store.state.error)
        XCTAssertFalse(store.state.isLoading)
    }

    private func makeStore() -> TestStoreOf<AppFeature> {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.taskClient.load = { ConnectedTasks(snapshot: TaskSnapshot(), account: nil) }
            $0.taskClient.connect = { ConnectedTasks(snapshot: TaskSnapshot(), account: "user@example.com") }
            $0.taskClient.disconnect = { ConnectedTasks(snapshot: TaskSnapshot(), account: nil) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }
}
