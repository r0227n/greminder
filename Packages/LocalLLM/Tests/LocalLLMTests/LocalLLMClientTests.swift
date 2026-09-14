import Foundation
@testable import LocalLLM
import XCTest

@MainActor
final class LocalLLMClientTests: XCTestCase {
    func testAppleModelIntegrationWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_LLM_INTEGRATION"] == "1" else {
            throw XCTSkip("Opt-in: requires the on-device Apple Intelligence model")
        }
        let client = LocalLLMClient()
        let model = LocalLLMModel.appleFoundationModels
        let availability = client.availability(model: model, locale: Locale(identifier: "en_US"))
        guard availability == .available else { throw XCTSkip("Model unavailable: \(availability)") }
        let text = try await client.generate(model: model, prompt: "Reply with the single word Hello.")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let plan = try await client.generateTaskPlan(model: model, prompt: """
        Today is 2026-09-14, timezone Asia/Tokyo.
        Task data: {"lists":[{"id":"work","title":"Work"}],"tasks":[]}
        User instruction: Add a task named Write outline to Work. No date or subtasks.
        """)
        XCTAssertEqual(plan.operations.count, 1)
        XCTAssertEqual(plan.operations.first?.kind, .add)
        XCTAssertEqual(plan.operations.first?.listID, "work")
        XCTAssertEqual(plan.operations.first?.date, "")
    }

    func testRoutesModelNamesAndPreservesPrompts() async throws {
        let client = LocalLLMClient(backends: [
            "first": StubBackend(text: { "first:" + $0 }),
            "second": StubBackend(text: { "second:" + $0 }),
        ])
        let first = try await client.generate(model: "first", prompt: "  hello  ")
        let second = try await client.generate(model: "second", prompt: "hello")
        XCTAssertEqual(first, "first:  hello  ")
        XCTAssertEqual(second, "second:hello")
    }

    func testUnknownModelFailsWithoutFallback() async {
        let client = LocalLLMClient()
        XCTAssertEqual(client.supportedModels, [LocalLLMModel.appleFoundationModels])
        XCTAssertEqual(client.availability(model: "missing"), .unsupportedModel)
        do {
            _ = try await client.generate(model: "missing", prompt: "hello")
            XCTFail("An unknown model must never run another provider")
        } catch {
            XCTAssertEqual(error as? LocalLLMError, .unsupportedModel("missing"))
        }
    }

    func testEmptyPromptIsRejectedBeforeInference() async {
        let client = LocalLLMClient(backends: ["test": StubBackend(text: { _ in
            XCTFail("Empty prompts must not reach inference")
            return ""
        })])
        do {
            _ = try await client.generate(model: "test", prompt: " \n ")
            XCTFail("Expected empty prompt error")
        } catch { XCTAssertEqual(error as? LocalLLMError, .emptyPrompt) }
    }

    func testStructuredPlanUsesSelectedBackend() async throws {
        let expected = TaskPlan(operations: [TaskPlanOperation(
            kind: .reschedule, taskID: "task", listID: "list", date: "2026-09-20",
        )])
        let client = LocalLLMClient(backends: ["test": StubBackend(plan: { prompt in
            XCTAssertEqual(prompt, "move the task")
            return expected
        })])
        let result = try await client.generateTaskPlan(model: "test", prompt: "move the task")
        XCTAssertEqual(result, expected)
        XCTAssertEqual(try JSONDecoder().decode(TaskPlan.self, from: JSONEncoder().encode(result)), expected)
    }

    func testAvailabilityUsesSelectedProviderAndLocale() {
        let client = LocalLLMClient(backends: ["test": StubBackend(status: {
            $0.identifier == "ja" ? .available : .unavailable(.unsupportedLocale)
        })])
        XCTAssertEqual(client.availability(model: "test", locale: Locale(identifier: "ja")), .available)
        XCTAssertEqual(
            client.availability(model: "test", locale: Locale(identifier: "en")),
            .unavailable(.unsupportedLocale),
        )
    }

    func testTypedFailureAndProviderFailureUseStableErrors() async {
        enum ProviderError: Error { case failed }
        let client = LocalLLMClient(backends: [
            "unavailable": StubBackend(text: { _ in throw LocalLLMError.modelUnavailable(.modelNotReady) }),
            "failed": StubBackend(text: { _ in throw ProviderError.failed }),
        ])
        for (model, expected) in [
            ("unavailable", LocalLLMError.modelUnavailable(.modelNotReady)),
            ("failed", LocalLLMError.generationFailed),
        ] {
            do {
                _ = try await client.generate(model: model, prompt: "hello")
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? LocalLLMError, expected) }
        }
    }

    func testCancellationDiscardsLateProviderResult() async {
        let gate = InferenceGate()
        let client = LocalLLMClient(backends: ["test": StubBackend(text: { _ in await gate.generate() })])
        let request = Task { try await client.generate(model: "test", prompt: "hello") }
        await gate.waitUntilStarted()
        request.cancel()
        await gate.finish()
        do {
            _ = try await request.value
            XCTFail("A cancelled request must discard late output")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testConcurrentCallsDoNotMixResults() async throws {
        let client = LocalLLMClient(backends: ["test": StubBackend(text: {
            await Task.yield()
            return $0
        })])
        let responses = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0 ..< 8 {
                group.addTask { try await client.generate(model: "test", prompt: "request-\(index)") }
            }
            var results = Set<String>()
            for try await response in group {
                results.insert(response)
            }
            return results
        }
        XCTAssertEqual(responses, Set((0 ..< 8).map { "request-\($0)" }))
    }
}

private struct StubBackend: LocalLLMBackend {
    var status: @Sendable (Locale) -> ModelAvailability = { _ in .available }
    var text: @Sendable (String) async throws -> String = { $0 }
    var plan: @Sendable (String) async throws -> TaskPlan = { _ in TaskPlan(operations: []) }
    func availability(locale: Locale) -> ModelAvailability { status(locale) }
    func generate(prompt: String) async throws -> String { try await text(prompt) }
    func generateTaskPlan(prompt: String) async throws -> TaskPlan { try await plan(prompt) }
}

private actor InferenceGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<String, Never>?

    func generate() async -> String {
        started = true
        startWaiter?.resume()
        return await withCheckedContinuation { resultWaiter = $0 }
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func finish() { resultWaiter?.resume(returning: "late result") }
}
