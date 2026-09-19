import ComposableArchitecture
@testable import GreminderKit
import Synchronization
import XCTest

@MainActor
final class SpeechSettingsTests: XCTestCase {
    func testPreferencesSurviveStoreRecreation() throws {
        let suite = "greminder.speech.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(try SpeechPreferences.load(from: defaults), SpeechPreferences())
        let selected = SpeechPreferences(model: .largeV3Turbo, language: .automatic)
        try selected.save(to: defaults)
        let recreated = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(try SpeechPreferences.load(from: recreated), selected)
    }

    func testSelectionsReachNextVoiceSessionAndModelPreparation() async {
        let saved = Mutex<[SpeechPreferences]>([])
        var prepared: SpeechPreferences?
        var state = AppFeature.State()
        state.snapshot = .sample()
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.speechSettings.load = { SpeechPreferences(model: .tiny, language: .english) }
            $0.speechSettings.save = { preferences in saved.withLock { $0.append(preferences) } }
            $0.speech.prepare = { _, preferences in await MainActor.run { prepared = preferences } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.speechSettings(.load))
        XCTAssertEqual(store.state.speechSettings.preferences.model, .tiny)
        await store.send(.speechSettings(.modelChanged(.largeV3Turbo)))
        await store.receive(\.speechSettings.modelPrepared)
        XCTAssertEqual(prepared, SpeechPreferences(model: .largeV3Turbo, language: .english))
        await store.send(.speechSettings(.languageChanged(.automatic)))
        await store.send(.openVoice(.task))
        let expected = SpeechPreferences(model: .largeV3Turbo, language: .automatic)
        XCTAssertEqual(store.state.voice.preferences, expected)
        await store.send(.voice(.prepare))
        await store.receive(\.voice.prepared)
        await store.finish()
        XCTAssertEqual(prepared, expected)
        XCTAssertEqual(saved.withLock { $0.last }, expected)
        XCTAssertEqual(store.state.voice.phase, .ready)
    }

    func testSaveFailureKeepsPreviousSelection() async {
        let store = TestStore(initialState: SpeechSettingsFeature.State()) { SpeechSettingsFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.speech.prepare = { _, _ in }
            $0.speechSettings.save = { _ in throw AppFailure("保存できません") }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.modelChanged(.small))
        await store.receive(\.modelPrepared)
        XCTAssertEqual(store.state.preferences.model, .base)
        XCTAssertFalse(store.state.isDownloading)
        XCTAssertNotNil(store.state.error)
    }

    func testModelChangeShowsLoadingUntilReadyAndReleasesSessionBeforeSaving() async {
        let gate = AsyncStream<Void>.makeStream()
        let prepared = Mutex<SpeechPreferences?>(nil)
        let released = Mutex<[UUID]>([])
        let saved = Mutex<[SpeechPreferences]>([])
        let id = UUID()
        let store = TestStore(initialState: SpeechSettingsFeature.State()) { SpeechSettingsFeature()
        } withDependencies: {
            $0.uuid = .constant(id)
            $0.speech.prepare = { sessionID, preferences in
                XCTAssertEqual(sessionID, id)
                prepared.withLock { $0 = preferences }
                for await _ in gate.stream {
                    break
                }
            }
            $0.speech.cancel = { sessionID in released.withLock { $0.append(sessionID) } }
            $0.speechSettings.save = { preferences in
                XCTAssertEqual(released.withLock { $0 }, [id])
                saved.withLock { $0.append(preferences) }
            }
        }
        await store.send(.modelChanged(.small)) {
            $0.downloadingModel = .small
        }
        XCTAssertTrue(store.state.isDownloading)
        XCTAssertEqual(store.state.preferences.model, .base)
        XCTAssertTrue(saved.withLock { $0.isEmpty })
        // UI and reducer both prevent overlapping selections while preparation is in flight.
        await store.send(.modelChanged(.tiny))
        await store.send(.languageChanged(.english))
        gate.continuation.yield(())
        gate.continuation.finish()
        await store.receive(\.modelPrepared) {
            $0.downloadingModel = nil
            $0.preferences.model = .small
            $0.isLoaded = true
        }
        await store.finish()
        XCTAssertEqual(prepared.withLock { $0 }, SpeechPreferences(model: .small))
        XCTAssertEqual(saved.withLock { $0 }, [SpeechPreferences(model: .small)])
    }

    func testDownloadFailureKeepsSelectionReleasesSessionAndAllowsRetry() async {
        let attempts = Mutex(0)
        let released = Mutex(0)
        let saved = Mutex<[SpeechPreferences]>([])
        let store = TestStore(initialState: SpeechSettingsFeature.State()) { SpeechSettingsFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.speech.prepare = { _, _ in
                let attempt = attempts.withLock { $0 += 1
                    return $0
                }
                if attempt == 1 { throw AppFailure("offline") }
            }
            $0.speech.cancel = { _ in released.withLock { $0 += 1 } }
            $0.speechSettings.save = { preferences in saved.withLock { $0.append(preferences) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.modelChanged(.tiny))
        await store.receive(\.modelPrepared)
        XCTAssertFalse(store.state.isDownloading)
        XCTAssertEqual(store.state.preferences.model, .base)
        XCTAssertTrue(store.state.error?.contains("offline") == true)
        XCTAssertTrue(saved.withLock { $0.isEmpty })
        XCTAssertEqual(released.withLock { $0 }, 1)
        await store.send(.modelChanged(.tiny))
        XCTAssertNil(store.state.error)
        await store.receive(\.modelPrepared)
        await store.finish()
        XCTAssertEqual(store.state.preferences.model, .tiny)
        XCTAssertFalse(store.state.isDownloading)
        XCTAssertEqual(released.withLock { $0 }, 2)
        XCTAssertEqual(saved.withLock { $0 }, [SpeechPreferences(model: .tiny)])
    }

    func testSelectingCurrentModelDoesNotPrepareAgain() async {
        let store = TestStore(initialState: SpeechSettingsFeature.State()) { SpeechSettingsFeature() }
        await store.send(.modelChanged(.base))
        await store.finish()
    }

    func testAutomaticDetectionAndExplicitLanguageDecodeDifferently() {
        let automatic = WhisperSpeechEngine.decodingOptions(for: .automatic)
        XCTAssertNil(automatic.language)
        XCTAssertTrue(automatic.detectLanguage)
        for language in SpeechLanguage.allCases where language != .automatic {
            let options = WhisperSpeechEngine.decodingOptions(for: language)
            XCTAssertEqual(options.language, language.rawValue)
            XCTAssertFalse(options.detectLanguage)
            XCTAssertEqual(options.task, .transcribe)
        }
    }
}
