@testable import GreminderKit
import XCTest

/// Runs in the iOS app host, so Core ML uses the Simulator runtime, not native macOS.
@MainActor
final class SpeechSimulatorTests: XCTestCase {
    func testLargeV3TurboTranscriptionAfterSwitchingFromSmall() async throws {
        guard ProcessInfo.processInfo.environment["GREMINDER_RUN_SPEECH_INTEGRATION"] == "1" else {
            throw XCTSkip("Opt-in: set GREMINDER_RUN_SPEECH_INTEGRATION=1; downloads the real model if uncached.")
        }
        let audio = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "japanese-task", withExtension: "aiff"))
        let sessionID = UUID()
        let engine = WhisperSpeechEngine()
        try await engine.prepare(SpeechPreferences(model: .small), sessionID: sessionID)
        let selections = [
            SpeechPreferences(model: .largeV3Turbo, language: .japanese),
            SpeechPreferences(model: .largeV3Turbo, language: .automatic),
        ]
        for preferences in selections {
            NSLog("SpeechSimulatorTests: prepare %@, %@", preferences.model.rawValue, preferences.language.rawValue)
            try await engine.prepare(preferences, sessionID: sessionID)
            NSLog("SpeechSimulatorTests: transcribe %@", preferences.language.rawValue)
            let text = try await engine.transcribeFile(audio)
            NSLog("SpeechSimulatorTests: result %@", text)
            XCTAssertTrue(text.contains("牛乳"), text)
            XCTAssertTrue(text.contains("買"), text)
        }
        try await engine.prepare(SpeechPreferences(model: .small), sessionID: sessionID)
    }

    /// Separate known accuracy issue on iOS 26.2 CPU inference; native macOS passes.
    /// Keep the assertions intact so the independent investigation stays reproducible.
    func testSmallJapaneseTranscriptionDiagnostic() async throws {
        guard ProcessInfo.processInfo.environment["GREMINDER_RUN_SMALL_DIAGNOSTICS"] == "1" else {
            throw XCTSkip("Separate Small accuracy diagnostic: see docs/diagnostics/large-v3-turbo-simulator.md")
        }
        let audio = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "japanese-task", withExtension: "aiff"))
        let sessionID = UUID()
        let engine = WhisperSpeechEngine()
        try await engine.prepare(SpeechPreferences(model: .small), sessionID: sessionID)
        let text = try await engine.transcribeFile(audio)
        XCTAssertTrue(text.contains("牛乳"), text)
        XCTAssertTrue(text.contains("買"), text)
    }
}
