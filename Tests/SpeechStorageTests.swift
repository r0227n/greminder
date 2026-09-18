import ComposableArchitecture
@testable import GreminderKit
import XCTest

final class SpeechStorageTests: XCTestCase {
    func testLowDiskRejectsLargeModelButAllowsSmall() throws {
        let defaults = UserDefaults.inMemory
        defaults.set("ja", forKey: L10n.preferenceKey)
        try withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            XCTAssertThrowsError(try SpeechStorage.validate(
                availableBytes: 3_865_470_566,
                model: .largeV3Turbo,
                onSimulator: true,
            )) { error in
                XCTAssertTrue((error as? AppFailure)?.message.contains("空き容量が不足") == true)
                XCTAssertTrue((error as? AppFailure)?.message.contains("8 GB") == true)
            }
            XCTAssertNoThrow(try SpeechStorage.validate(availableBytes: 800_000_000, model: .small, onSimulator: true))
        }
    }

    func testUnavailableCapacityFailsBeforeLoadingAndFreedSpaceAllowsRetry() {
        for simulator in [false, true] {
            XCTAssertThrowsError(try SpeechStorage.validate(
                availableBytes: nil,
                model: .largeV3Turbo,
                onSimulator: simulator,
            ))
            let required = SpeechStorage.requiredFreeBytes(for: .largeV3Turbo, onSimulator: simulator)
            XCTAssertThrowsError(try SpeechStorage.validate(
                availableBytes: required - 1,
                model: .largeV3Turbo,
                onSimulator: simulator,
            ))
            XCTAssertNoThrow(try SpeechStorage.validate(
                availableBytes: required,
                model: .largeV3Turbo,
                onSimulator: simulator,
            ))
        }
    }

    @MainActor
    func testEngineRejectsBeforeDownloadOrCoreMLLoad() async throws {
        let defaults = UserDefaults.inMemory
        defaults.set("ja", forKey: L10n.preferenceKey)
        try await withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: cache) }
            let engine = WhisperSpeechEngine(modelCache: cache, availableBytes: { _ in 100_000_000 })
            do {
                try await engine.prepare(SpeechPreferences(model: .largeV3Turbo), sessionID: UUID())
                XCTFail("Low storage must fail before the SDK is invoked")
            } catch {
                XCTAssertTrue((error as? AppFailure)?.message.contains("空き容量が不足") == true)
            }
            // No weights, model marker, or download metadata should have been created.
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
        }
    }

    @MainActor
    func testPreparationAndCancellationAreOwnedByOneVoiceSession() async throws {
        let defaults = UserDefaults.inMemory
        defaults.set("ja", forKey: L10n.preferenceKey)
        await withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: cache) }
            let gate = SpeechModelLoadGate()
            let engine = WhisperSpeechEngine(modelCache: cache, availableBytes: { _ in 10_000_000_000 }) { _, _ in
                await gate.load()
                throw AppFailure("Stub model load failed")
            }
            let owner = UUID()
            let otherWindow = UUID()
            let preparation = Task { try await engine.prepare(SpeechPreferences(), sessionID: owner) }
            await gate.waitUntilStarted()
            engine.cancel(id: otherWindow)
            do {
                try await engine.prepare(SpeechPreferences(model: .tiny, language: .english), sessionID: otherWindow)
                XCTFail("Another window must not replace the active session's model or language")
            } catch {
                XCTAssertTrue((error as? AppFailure)?.message.contains("別のウインドウ") == true)
            }
            engine.cancel(id: owner)
            gate.finish()
            do {
                try await preparation.value
                XCTFail("The owning session's cancellation must discard the late loader failure")
            } catch { XCTAssertTrue(error is CancellationError) }
            do {
                try await engine.prepare(SpeechPreferences(model: .tiny), sessionID: otherWindow)
                XCTFail("The stub loader always fails")
            } catch {
                XCTAssertEqual(error as? AppFailure, AppFailure("Stub model load failed"))
            }
        }
    }
}

@MainActor
private final class SpeechModelLoadGate {
    private var started = false
    private var finished = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var loadWaiter: CheckedContinuation<Void, Never>?

    func load() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        if !finished { await withCheckedContinuation { loadWaiter = $0 } }
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func finish() {
        finished = true
        loadWaiter?.resume()
        loadWaiter = nil
    }
}
