import ComposableArchitecture
import Foundation
import LocalLLM

struct TaskProposal: Equatable, Sendable, Identifiable {
    enum Operation: String, Sendable { case add, reschedule, complete }
    var id = UUID()
    var operation: Operation
    var task: ReminderTask
    var subtasks: [String] = []
}

struct LocalAIClient: Sendable {
    var availability: @Sendable () -> String?
    var propose: @Sendable (String, TaskSnapshot, TaskDay) async throws -> [TaskProposal]
}

extension LocalAIClient: DependencyKey {
    static let model = LocalLLMModel.appleFoundationModels
    private static let client = LocalLLMClient()

    static func unavailableReason() -> String? {
        switch client.availability(model: model, locale: L10n.locale) {
        case .available: nil
        case let .unavailable(reason): message(for: reason)
        case .unsupportedModel: L10n.tr("指定されたAIモデルには対応していません。")
        }
    }

    static let liveValue: Self = .init(availability: { unavailableReason() }, propose: { input, snapshot, today in
        if let reason = unavailableReason() { throw AppFailure(reason) }
        guard input.count <= TaskInputPolicy.promptLimit else { throw AppFailure(L10n.tr("指示は1,500文字以内にしてください。")) }
        guard snapshot.tasks.count <= 80 else { throw AppFailure(L10n.tr("AIで操作するリストを絞り込んでください（80件以内）。")) }
        let context = try String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self)
        let prompt = """
        Today is \(today.value), timezone \(TimeZone.current.identifier).
        Task data:
        \(context)
        User instruction:
        \(input)
        """
        do {
            let plan = try await client.generateTaskPlan(model: model, prompt: prompt)
            return try validate(plan, snapshot: snapshot)
        } catch let error as LocalLLMError {
            switch error {
            case let .modelUnavailable(reason): throw AppFailure(message(for: reason))
            case .unsupportedModel: throw AppFailure(L10n.tr("指定されたAIモデルには対応していません。"))
            case .emptyPrompt: throw AppFailure(L10n.tr("AIへの指示を入力してください。"))
            case .generationFailed: throw AppFailure(L10n.tr("AI処理に失敗しました。もう一度お試しください。"))
            }
        }
    })

    private static func message(for reason: ModelUnavailableReason) -> String {
        switch reason {
        case .unsupportedLocale: L10n.tr("選択した言語のAI処理を利用できません。")
        case .intelligenceNotEnabled: L10n.tr("Apple Intelligenceを有効にするとAIを利用できます。")
        case .modelNotReady: L10n.tr("端末内のAIを準備中です。後でもう一度お試しください。")
        case .deviceNotEligible: L10n.tr("このデバイスでは端末内AIを利用できません。")
        case .unknown: L10n.tr("現在、端末内AIを利用できません。")
        }
    }

    static let testValue = Self(
        availability: { nil },
        propose: { _, _, _ in throw AppFailure("AI dependency must be supplied") },
    )

    static func validate(_ plan: TaskPlan, snapshot: TaskSnapshot) throws -> [TaskProposal] {
        guard (1 ... 10).contains(plan.operations.count) else {
            throw AppFailure(L10n.tr("対象を特定できませんでした。タスク名と変更内容を具体的に入力してください。"))
        }
        var targets = Set<String>()
        return try plan.operations.map { operation in
            guard snapshot.lists.contains(where: { $0.id == operation.listID })
            else { throw AppFailure(L10n.tr("対象リストを確認できませんでした。")) }
            let day = operation.date.isEmpty ? nil : TaskDay(operation.date)
            guard operation.date.isEmpty || day != nil else { throw AppFailure(L10n.tr("予定日を確認できませんでした。")) }
            switch operation.kind {
            case .add:
                let title = operation.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count <= TaskInputPolicy.titleLimit, operation.subtasks.count <= 10,
                      operation.subtasks
                      .allSatisfy({
                          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= TaskInputPolicy
                              .titleLimit })
                else {
                    throw AppFailure(L10n.tr("タスクの内容を確認できませんでした。"))
                }
                return TaskProposal(
                    operation: .add,
                    task: ReminderTask(id: UUID().uuidString, listID: operation.listID, title: title, due: day),
                    subtasks: operation.subtasks,
                )
            case .reschedule, .complete:
                guard var task = snapshot.tasks
                    .first(where: { $0.id == operation.taskID && $0.listID == operation.listID }),
                    targets.insert(task.id).inserted else { throw AppFailure(L10n.tr("対象タスクを一意に確認できませんでした。")) }
                if operation.kind == .reschedule {
                    guard let day else { throw AppFailure(L10n.tr("変更先の予定日を指定してください。")) }
                    task.due = day
                } else { task.isCompleted = true }
                return TaskProposal(operation: operation.kind == .reschedule ? .reschedule : .complete, task: task)
            }
        }
    }
}

extension DependencyValues {
    var localAI: LocalAIClient {
        get { self[LocalAIClient.self] }
        set { self[LocalAIClient.self] = newValue }
    }
}
