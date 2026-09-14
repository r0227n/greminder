import ComposableArchitecture
import Foundation

extension AppFeature {
    func reduceAI(into state: inout State, action: Action) -> Effect<Action>? {
        switch action {
        case .askAI:
            let input = state.aiText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty, !state.isThinking, !state.isLoading, !state.showsVoice else { return Effect.none }
            commit(&state)
            guard state.editor == nil else { return Effect.none }
            guard state.pending.isEmpty else { state.error = L10n.tr("保存が完了してからAIに指示してください。")
                return .send(.processQueue)
            }
            let request = AIRequest(id: uuid(), context: AIContext(snapshot: state.snapshot, account: state.account))
            state.aiRequest = request
            state.proposalBatch = nil
            let context: TaskSnapshot = if case let .list(id) = state.selection {
                TaskSnapshot(
                    lists: state.snapshot.lists.filter { $0.id == id },
                    tasks: state.snapshot.tasks.filter { $0.listID == id },
                )
            } else { state.snapshot }
            return .run { [today = state.today] send in
                do {
                    let proposals = try await ai.propose(input, context, today)
                    try Task.checkCancellation()
                    await send(.aiResult(request.id, .success(proposals)))
                } catch is CancellationError {
                    // Cancelling or changing the request must not produce a late error/result.
                } catch {
                    guard !Task.isCancelled else { return }
                    await send(.aiResult(request.id, .failure(AppFailure(error))))
                }
            }.cancellable(id: CancelID.ai(request.id), cancelInFlight: true)
        case let .aiResult(id, result):
            guard let request = state.aiRequest, request.id == id else { return Effect.none }
            state.aiRequest = nil
            switch result {
            case let .success(proposals):
                state.proposalBatch = AIProposalBatch(context: request.context, proposals: proposals)
            case let .failure(error): state.error = error.message
            }
            return Effect.none
        case .showExample:
            guard !state.isLoading, !state.showsVoice, let listID = state.defaultListID else { return Effect.none }
            let tomorrow = TaskDay(date: Calendar.current.date(byAdding: .day, value: 1, to: state.today.date)!)
            state.aiText = L10n.tr("明日までに企画書を書く。構成と下書きも追加")
            let cancellation = cancelAI(&state)
            state.proposalBatch = AIProposalBatch(
                context: AIContext(snapshot: state.snapshot, account: state.account),
                proposals: [TaskProposal(
                    operation: .add,
                    task: ReminderTask(
                        id: uuid().uuidString,
                        listID: listID,
                        title: L10n.tr("企画書を書く"),
                        due: tomorrow,
                    ),
                    subtasks: [L10n.tr("構成を考える"), L10n.tr("下書きを作る")],
                )],
                isExample: true,
            )
            return cancellation
        case .cancelProposal:
            let cancellation = cancelAI(&state)
            state.proposalBatch = nil
            return cancellation
        case .applyProposal:
            guard !state.isLoading, !state.showsVoice, !state.isThinking else { return Effect.none }
            commit(&state)
            guard state.editor == nil, let batch = state.proposalBatch,
                  batch.context == AIContext(snapshot: state.snapshot, account: state.account),
                  state.pending.isEmpty
            else {
                state.error = L10n.tr("タスクが変更されました。もう一度指示を送ってください。")
                state.proposalBatch = nil
                return .send(.processQueue)
            }
            for proposal in state.proposals {
                if proposal.operation == .add {
                    let previous = state.snapshot.tasks
                        .last { $0.listID == proposal.task.listID && $0.parentID == nil }?.id
                    state.snapshot.tasks.append(proposal.task)
                    state.pending.append(PendingWrite(task: proposal.task, previousID: previous))
                    var previousChild: String?
                    for title in proposal.subtasks {
                        let task = ReminderTask(
                            id: uuid().uuidString,
                            listID: proposal.task.listID,
                            title: title,
                            parentID: proposal.task.id,
                        )
                        state.snapshot.tasks.append(task)
                        state.pending.append(PendingWrite(task: task, previousID: previousChild))
                        previousChild = task.id
                    }
                } else if let index = state.snapshot.tasks.firstIndex(where: { $0.id == proposal.task.id }) {
                    state.snapshot.tasks[index] = proposal.task
                    state.pending.append(PendingWrite(task: proposal.task))
                }
            }
            if let first = state.proposals.first { state.selection = .list(first.task.listID) }
            state.proposalBatch = nil
            state.aiText = ""
            return .send(.processQueue)
        default: return nil
        }
    }

    func cancelAI(_ state: inout State) -> Effect<Action> {
        let requestID = state.aiRequest?.id
        state.aiRequest = nil
        return requestID.map { .cancel(id: CancelID.ai($0)) } ?? .none
    }
}
