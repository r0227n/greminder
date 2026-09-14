@testable import GreminderKit
import XCTest

@MainActor
final class WhisperIntegrationTests: XCTestCase {
    func testJapaneseSpeechWithRealWhisperKit() async throws {
        guard let path = ProcessInfo.processInfo.environment["GREMINDER_TEST_AUDIO"],
              let cache = ProcessInfo.processInfo.environment["GREMINDER_TEST_MODEL_CACHE"]
        else {
            throw XCTSkip(
                "Opt-in: requires a synthetic speech fixture and a local model cache; no microphone or download in normal CI.",
            )
        }
        let modelName = ProcessInfo.processInfo.environment["GREMINDER_TEST_MODEL"] ?? SpeechModel.base.rawValue
        let model = try XCTUnwrap(SpeechModel(rawValue: modelName))
        let sessionID = UUID()
        let engine = WhisperSpeechEngine(modelCache: URL(fileURLWithPath: cache))
        try await engine.prepare(SpeechPreferences(model: model, language: .japanese), sessionID: sessionID)
        let text = try await engine.transcribeFile(URL(fileURLWithPath: path))
        XCTAssertTrue(text.contains("牛乳"), "WhisperKit transcript: \(text)")
        XCTAssertTrue(text.contains("買"), "WhisperKit transcript: \(text)")
        try await engine.prepare(SpeechPreferences(model: model, language: .automatic), sessionID: sessionID)
        let detected = try await engine.transcribeFile(URL(fileURLWithPath: path))
        XCTAssertTrue(detected.contains("牛乳"), "WhisperKit automatic language transcript: \(detected)")
    }
}
