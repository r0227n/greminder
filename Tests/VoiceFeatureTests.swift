import ComposableArchitecture
@testable import GreminderKit
import Synchronization
import XCTest

@MainActor
final class VoiceFeatureTests: XCTestCase {
    func testSeparateWindowsDoNotCancelEachOthersPreparationEffects() async {
        let clock = TestClock()
        let firstID = UUID()
        let secondID = UUID()
        let first = TestStore(initialState: VoiceFeature.State()) { VoiceFeature() } withDependencies: {
            $0.uuid = .constant(firstID)
            $0.speech.prepare = { _, _ in try await clock.sleep(for: .seconds(1)) }
        }
        let second = TestStore(initialState: VoiceFeature.State()) { VoiceFeature() } withDependencies: {
            $0.uuid = .constant(secondID)
            $0.speech.prepare = { _, _ in try await clock.sleep(for: .seconds(1)) }
        }
        await first.send(.prepare) {
            $0.phase = .preparing
            $0.sessionID = firstID
        }
        await second.send(.prepare) {
            $0.phase = .preparing
            $0.sessionID = secondID
        }
        await clock.advance(by: .seconds(1))
        await first.receive(\.prepared) { $0.phase = .ready }
        await second.receive(\.prepared) { $0.phase = .ready }
        await first.finish()
        await second.finish()
    }

    func testPreparationResponseFromDismissedSessionCannotReadyAnotherSession() async {
        let oldID = UUID()
        let newID = UUID()
        let store = TestStore(initialState: VoiceFeature.State(phase: .preparing, sessionID: newID)) {
            VoiceFeature()
        }
        await store.send(.prepared(oldID, .success(())))
        await store.send(.prepared(oldID, .failure(AppFailure("Old failure"))))
        await store.send(.prepared(newID, .success(()))) { $0.phase = .ready }
    }

    func testClosingUnpreparedSheetDoesNotCancelAnotherWindow() async {
        let store = TestStore(initialState: VoiceFeature.State()) { VoiceFeature() } withDependencies: {
            $0.speech.cancel = { _ in XCTFail("An unprepared sheet owns no speech session") }
        }
        await store.send(.cancel)
        await store.finish()
    }

    func testReadySessionRetainsItsIdentityUntilExplicitClose() async {
        let id = UUID()
        let cancelled = Mutex<[UUID]>([])
        let store = TestStore(initialState: VoiceFeature.State(phase: .ready, sessionID: id)) {
            VoiceFeature()
        } withDependencies: {
            $0.speech.cancel = { id in cancelled.withLock { $0.append(id) } }
        }
        await store.send(.cancel) {
            $0.phase = .idle
            $0.sessionID = nil
        }
        await store.finish()
        XCTAssertEqual(cancelled.withLock { $0 }, [id])
    }

    func testLowStorageShowsErrorAndCanRetryAfterFreeingSpace() async {
        let capacity = Mutex<Int64>(100_000_000)
        var state = VoiceFeature.State()
        state.preferences.model = .largeV3Turbo
        let store = TestStore(initialState: state) { VoiceFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.speech.prepare = { _, preferences in
                try SpeechStorage.validate(
                    availableBytes: capacity.withLock { $0 }, model: preferences.model, onSimulator: true,
                )
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.prepare)
        await store.receive(\.prepared)
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertTrue(store.state.error?.contains("空き容量が不足") == true)
        XCTAssertTrue(store.state.error?.contains("8 GB") == true)
        capacity.withLock { $0 = 10_000_000_000 }
        await store.send(.prepare)
        await store.receive(\.prepared)
        XCTAssertEqual(store.state.phase, .ready)
        XCTAssertNil(store.state.error)
        await store.finish()
    }

    func testRecordStopReviewThenExplicitAcceptance() async throws {
        let clock = TestClock()
        let store = TestStore(initialState: VoiceFeature.State(phase: .ready, sessionID: UUID())) { VoiceFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.speech.start = { _ in }
            $0.speech.transcribe = { _ in "コーヒー豆を買う" }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.record)
        await store.receive(\.recordingStarted)
        XCTAssertEqual(store.state.phase, .recording)
        await clock.advance(by: .seconds(1))
        await store.receive(\.tick)
        XCTAssertEqual(store.state.seconds, 1)
        await store.send(.stop)
        await store.receive(\.transcribed)
        XCTAssertEqual(store.state.phase, .review)
        XCTAssertEqual(store.state.transcript, "コーヒー豆を買う")
        await store.send(.accept)
        await store.receive(\.delegate)
        await store.finish()
    }

    func testCancelDiscardsLateResultAndStopsSession() async {
        let id = UUID()
        var cancelled: UUID?
        let store = TestStore(initialState: VoiceFeature.State(phase: .transcribing, sessionID: id)) { VoiceFeature()
        } withDependencies: {
            $0.speech.cancel = { value in await MainActor.run { cancelled = value } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.cancel)
        await store.finish()
        await store.send(.transcribed(id, .success("取り消した音声")))
        XCTAssertEqual(cancelled, id)
        XCTAssertEqual(store.state.transcript, "")
        XCTAssertEqual(store.state.phase, .idle)
    }

    func testPermissionFailurePreservesPreviousTranscript() async {
        let store = TestStore(initialState: VoiceFeature.State(phase: .review, transcript: "前の結果", sessionID: UUID())) {
            VoiceFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.speech.start = { _ in throw AppFailure("マイクが許可されていません") }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.record)
        await store.receive(\.recordingStarted)
        XCTAssertEqual(store.state.phase, .review)
        XCTAssertEqual(store.state.transcript, "前の結果")
        XCTAssertNotNil(store.state.error)
        await store.finish()
    }

    func testTranscriptPopulatesTaskEditorWithoutSavingOrCallingAI() async {
        var state = AppFeature.State()
        state.snapshot = .sample()
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.openVoice(.task))
        await store.send(.voice(.delegate(.transcript("牛乳を買う", .task))))
        await store.finish()
        XCTAssertEqual(store.state.editor?.task.title, "牛乳を買う")
        XCTAssertTrue(store.state.pending.isEmpty)
        XCTAssertEqual(store.state.snapshot.tasks.count, 10)
        XCTAssertFalse(store.state.showsVoice)
    }

    func testSixtySecondLimitStopsRecording() async {
        let id = UUID()
        let store = TestStore(initialState: VoiceFeature.State(phase: .recording, seconds: 59, sessionID: id)) {
            VoiceFeature()
        } withDependencies: {
            $0.speech.transcribe = { _ in "60秒で停止" }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.tick(id))
        await store.receive(\.stop)
        await store.receive(\.transcribed)
        await store.finish()
        XCTAssertEqual(store.state.phase, .review)
    }
}
