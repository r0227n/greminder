import Foundation

public enum LocalLLMModel {
    public static let appleFoundationModels = "apple.foundation-models"
}

public enum ModelUnavailableReason: Equatable, Sendable {
    case intelligenceNotEnabled, modelNotReady, deviceNotEligible, unsupportedLocale, unknown
}

public enum ModelAvailability: Equatable, Sendable {
    case available
    case unavailable(ModelUnavailableReason)
    case unsupportedModel
}

public enum LocalLLMError: Error, Equatable, Sendable {
    case unsupportedModel(String)
    case modelUnavailable(ModelUnavailableReason)
    case emptyPrompt
    case generationFailed
}

/// A reusable, stateless client. Each request owns its inference session.
/// Model routing and inference SDKs are implementation details of this package.
public final class LocalLLMClient: Sendable {
    private let backends: [String: any LocalLLMBackend]

    public init() {
        backends = [LocalLLMModel.appleFoundationModels: AppleFoundationModelsBackend()]
    }

    // Internal injection keeps simulated models out of the production model catalog.
    init(backends: [String: any LocalLLMBackend]) {
        self.backends = backends
    }

    public var supportedModels: [String] { backends.keys.sorted() }

    public func availability(model: String, locale: Locale = .current) -> ModelAvailability {
        backends[model]?.availability(locale: locale) ?? .unsupportedModel
    }

    public func generate(model: String, prompt: String) async throws -> String {
        try await perform(model: model, prompt: prompt) { backend, prompt in
            try await backend.generate(prompt: prompt)
        }
    }

    /// A model-independent task plan, without SDK-specific generated-content types.
    public func generateTaskPlan(model: String, prompt: String) async throws -> TaskPlan {
        try await perform(model: model, prompt: prompt) { backend, prompt in
            try await backend.generateTaskPlan(prompt: prompt)
        }
    }

    private func perform<Output: Sendable>(
        model: String,
        prompt: String,
        operation: @Sendable (any LocalLLMBackend, String) async throws -> Output,
    ) async throws -> Output {
        try Task.checkCancellation()
        guard let backend = backends[model] else { throw LocalLLMError.unsupportedModel(model) }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalLLMError.emptyPrompt
        }
        do {
            let result = try await operation(backend, prompt)
            try Task.checkCancellation()
            return result
        } catch {
            // Even providers that return late or wrap cancellation cannot deliver a stale result.
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if let error = error as? LocalLLMError { throw error }
            throw LocalLLMError.generationFailed
        }
    }
}

protocol LocalLLMBackend: Sendable {
    func availability(locale: Locale) -> ModelAvailability
    func generate(prompt: String) async throws -> String
    func generateTaskPlan(prompt: String) async throws -> TaskPlan
}
