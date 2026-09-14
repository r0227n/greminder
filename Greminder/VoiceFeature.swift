import ComposableArchitecture
import Foundation

enum VoiceDestination: Equatable, Sendable { case task, ai }

@Reducer
struct VoiceFeature {
    enum Phase: Equatable { case idle, preparing, ready, requestingPermission, recording, transcribing, review }
    @ObservableState
    struct State: Equatable {
        var phase = Phase.idle
        var transcript = ""
        var error: String?
        var seconds = 0
        var sessionID: UUID?
        var destination = VoiceDestination.task
        var preferences = SpeechPreferences()
        var isBusy: Bool { [.preparing, .requestingPermission, .recording, .transcribing].contains(phase) }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case prepare
        case prepared(UUID, Result<Void, AppFailure>)
        case record
        case recordingStarted(UUID, Result<Void, AppFailure>)
        case tick(UUID)
        case stop
        case transcribed(UUID, Result<String, AppFailure>)
        case cancel
        case accept
        case delegate(Delegate)
        enum Delegate: Equatable { case transcript(String, VoiceDestination) }
    }

    @Dependency(\.speech) var speech
    @Dependency(\.continuousClock) var clock
    @Dependency(\.uuid) var uuid
    enum CancelID: Hashable { case work(UUID), timer(UUID) }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding, .delegate: return .none
            case .prepare:
                guard state.phase == .idle else { return .none }
                let id = uuid()
                state.sessionID = id
                state.phase = .preparing
                state.error = nil
                return .run { [preferences = state.preferences] send in
                    do { try await speech.prepare(id, preferences)
                        try Task.checkCancellation()
                        await send(.prepared(id, .success(())))
                    } catch is CancellationError {}
                    catch { await send(.prepared(id, .failure(AppFailure(error)))) }
                }.cancellable(id: CancelID.work(id), cancelInFlight: true)
            case let .prepared(id, .success):
                guard state.sessionID == id, state.phase == .preparing else { return .none }
                state.phase = .ready
                return .none
            case let .prepared(id, .failure(error)):
                guard state.sessionID == id, state.phase == .preparing else { return .none }
                state.phase = .idle
                state.sessionID = nil
                state.error = L10n.tr("モデルを準備できませんでした。接続と空き容量を確認して再試行してください。\n%@", String(describing: error.message))
                return .none
            case .record:
                guard [.ready, .review].contains(state.phase), let id = state.sessionID else { return .none }
                state.phase = .requestingPermission
                state.seconds = 0
                state.error = nil
                return .run { send in
                    do { try await speech.start(id)
                        try Task.checkCancellation()
                        await send(.recordingStarted(id, .success(())))
                    } catch is CancellationError {}
                    catch { await send(.recordingStarted(id, .failure(AppFailure(error)))) }
                }.cancellable(id: CancelID.work(id), cancelInFlight: true)
            case let .recordingStarted(id, .success):
                guard state.sessionID == id, state.phase == .requestingPermission else { return .none }
                state.phase = .recording
                return .run { send in
                    for await _ in clock.timer(interval: .seconds(1)) {
                        await send(.tick(id))
                    }
                }.cancellable(id: CancelID.timer(id), cancelInFlight: true)
            case let .recordingStarted(id, .failure(error)):
                guard state.sessionID == id, state.phase == .requestingPermission else { return .none }
                state.phase = state.transcript.isEmpty ? .ready : .review
                state.error = error.message
                return .none
            case let .tick(id):
                guard state.sessionID == id, state.phase == .recording else { return .none }
                state.seconds += 1
                return state.seconds >= SpeechClient.maximumRecordingSeconds ? .send(.stop) : .none
            case .stop:
                guard state.phase == .recording, let id = state.sessionID else { return .none }
                state.phase = .transcribing
                return .merge(.cancel(id: CancelID.timer(id)), .run { send in
                    do { let text = try await speech.transcribe(id)
                        try Task.checkCancellation()
                        await send(.transcribed(id, .success(text)))
                    } catch is CancellationError {}
                    catch { await send(.transcribed(id, .failure(AppFailure(error)))) }
                }.cancellable(id: CancelID.work(id), cancelInFlight: true))
            case let .transcribed(id, .success(text)):
                guard state.sessionID == id, state.phase == .transcribing else { return .none }
                state.transcript = text
                state.phase = .review
                return .none
            case let .transcribed(id, .failure(error)):
                guard state.sessionID == id, state.phase == .transcribing else { return .none }
                state.phase = state.transcript.isEmpty ? .ready : .review
                state.error = error.message
                return .none
            case .cancel:
                let id = state.sessionID
                state.sessionID = nil
                state.phase = .idle
                guard let id else { return .none }
                return .merge(
                    .cancel(id: CancelID.work(id)),
                    .cancel(id: CancelID.timer(id)),
                    .run { _ in await speech.cancel(id) },
                )
            case .accept:
                let text = state.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let limit = state.destination == .task ? TaskInputPolicy.titleLimit : TaskInputPolicy.promptLimit
                guard state.phase == .review, !text.isEmpty else { return .none }
                guard text.count <= limit else { state.error = L10n.tr("%@文字以内に編集してください。", String(describing: limit))
                    return .none
                }
                return .send(.delegate(.transcript(text, state.destination)))
            }
        }
    }
}
