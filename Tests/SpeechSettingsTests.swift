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
            $0.speechSettings.save = { _ in throw AppFailure("保存できません") }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.modelChanged(.small))
        XCTAssertEqual(store.state.preferences.model, .base)
        XCTAssertNotNil(store.state.error)
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
