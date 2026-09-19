import ComposableArchitecture
import Foundation
import GoogleSignIn
import SwiftUI

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var snapshot = TaskSnapshot()
        var selection: TaskSelection = .today
        var today = TaskDay.today
        var editor: TaskEditor?
        var showsTaskDetails = false
        var search = ""
        var collapsed: Set<String> = []
        var pending: [PendingWrite] = []
        var pendingNotificationEdits: [String: TaskNotificationEdit] = [:]
        var sharedAwaitingNotification: Set<String> = []
        var isSaving = false
        var writeFailed = false
        var hasLoadedTasks = false
        var pendingNotificationKey: String?
        var waitsForNotificationDismissal = false
        #if DEBUG
            var showsDebug = false
        #endif
        var isLoading = false
        var reloadAfterWrites = false
        var account: String?
        var googleAccount: GoogleAccountProfile?
        var accountMenuSource: String?
        var signedInAccounts: [GoogleAccountProfile] {
            if let googleAccount { return [googleAccount] }
            return account.map { [GoogleAccountProfile(id: $0, email: $0, name: "")] } ?? []
        }

        var isSignedIn: Bool { account != nil }
        var showsSampleTasks = false
        var usesMockAPI = false
        var canNavigateToTasks: Bool { isSignedIn || showsSampleTasks }
        var error: String?
        var message: String?
        var aiText = ""
        var aiRequest: AIRequest?
        var aiUnavailable: String?
        var proposalBatch: AIProposalBatch?
        var proposals: [TaskProposal] { proposalBatch?.proposals ?? [] }
        var isThinking: Bool { aiRequest != nil }
        var isExample: Bool { proposalBatch?.isExample ?? false }
        var showsSettings = false
        var showsNewList = false
        var newListTitle = ""
        var newListAppearance = ListAppearance()
        @Shared(.appStorage(L10n.preferenceKey)) var displayLanguage = L10n.initialLanguage
        var deleteCandidate: ReminderTask?
        var showsSearch = false
        var showsAIComposer = true
        var compactColumn = NavigationSplitViewColumn.detail
        var voice = VoiceFeature.State()
        var showsVoice = false
        var voiceEditorID: String?
        var notifications = NotificationFeature.State()
        var speechSettings = SpeechSettingsFeature.State()

        var title: String {
            if case let .list(id) = selection { return snapshot.lists.first { $0.id == id }?.title ?? L10n.tr("リスト") }
            return selection.title
        }

        var defaultListID: String? {
            if case let .list(id) = selection { return id }
            return snapshot.lists.first?.id
        }

        var matchingTasks: [ReminderTask] {
            snapshot.tasks(for: selection, today: today)
        }

        var searchResults: [ReminderTask] {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return [] }
            return snapshot.tasks.filter {
                $0.title.localizedStandardContains(query) || $0.notes.localizedStandardContains(query)
            }
        }

        var visibleTasks: [ReminderTask] {
            let matching = matchingTasks
            let ids = Set(matching.map(\.id))
            var result: [ReminderTask] = []
            for task in matching where task.parentID == nil || !ids.contains(task.parentID!) {
                result.append(task)
                if !collapsed.contains(task.id) { result += matching.filter { $0.parentID == task.id } }
            }
            return result
        }

        var visibleCount: Int { matchingTasks.count }
        var canSwitchAccount: Bool {
            pending.isEmpty && sharedAwaitingNotification.isEmpty && pendingNotificationEdits
                .isEmpty && !isLoading && editor == nil && !showsVoice && !isThinking
        }

        var proposedCount: Int { proposals.reduce(0) { $0 + 1 + $1.subtasks.count } }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case notificationTapped(String)
        case notificationPresentationDismissed
        case resumeNotificationNavigation
        case appeared
        case setSampleMode(Bool)
        case setUsesMockAPI(Bool)
        case signInAccount
        case signOutAccount
        case apiModeChanged(Bool, Result<ConnectedTasks, AppFailure>)
        case displayLanguageChanged(DisplayLanguage)
        case reload
        case loaded(Result<ConnectedTasks, AppFailure>)
        case select(TaskSelection)
        case beginAdd(after: String?, parent: String?)
        case edit(String)
        case openDetails(String)
        case openSearchResult(String)
        case saveDetails(String)
        case closeDetails
        case editorTitle(String)
        case editorNotes(String)
        case editorSchedule(String, TaskScheduleChange)
        case commitEditor(continueAdding: Bool)
        case cancelEditor
        case blankClicked
        case toggleComplete(String)
        case toggleChildren(String)
        case requestDelete(String)
        case swipeDelete(String)
        case confirmDelete
        case processQueue
        case writeFinished(UUID, Result<ReminderTask, AppFailure>)
        case retryWrites
        case dismissError
        case addList
        case listAdded(Result<TaskList, AppFailure>)
        case connect
        case signInCancelled
        case disconnect
        case askAI
        case aiResult(UUID, Result<[TaskProposal], AppFailure>)
        case showExample
        case cancelProposal
        case applyProposal
        case openVoice(VoiceDestination)
        case closeVoice
        case voice(VoiceFeature.Action)
        case notifications(NotificationFeature.Action)
        case speechSettings(SpeechSettingsFeature.Action)
        case foreground
        case checkSharedTasks
        case sharePersistenceFailed(AppFailure)
    }

    @Dependency(\.taskClient) var tasks
    @Dependency(\.localAI) var ai
    @Dependency(\.uuid) var uuid
    @Dependency(\.shareInbox) var shareInbox
    enum CancelID: Hashable, Sendable { case ai(UUID) }

    var body: some ReducerOf<Self> {
        Scope(state: \.voice, action: \.voice) { VoiceFeature() }
        Scope(state: \.notifications, action: \.notifications) { NotificationFeature() }
        Scope(state: \.speechSettings, action: \.speechSettings) { SpeechSettingsFeature() }
        BindingReducer()
        Reduce { state, action in
            if let effect = reduceNotificationNavigation(into: &state, action: action) { return effect }
            if let effect = reduceAI(into: &state, action: action) { return effect }
            switch action {
            case let .openVoice(destination):
                guard !state.showsVoice, !state.isLoading, !state.isThinking else { return .none }
                if destination == .task, state.editor == nil { begin(&state, after: nil, parent: nil) }
                if destination == .task, state.editor == nil { return .none }
                state.voice = VoiceFeature.State(
                    destination: destination,
                    preferences: state.speechSettings.preferences,
                )
                state.voiceEditorID = state.editor?.id
                state.showsVoice = true
                return .send(.voice(.prepare))
            case .closeVoice:
                state.showsVoice = false
                return .send(.voice(.cancel))
            case let .voice(.delegate(.transcript(text, destination))):
                guard state.showsVoice else { return .none }
                if destination == .task {
                    guard state.editor?.id == state.voiceEditorID else {
                        state.voice.error = L10n.tr("入力先のタスクが変わりました。音声入力を閉じて、もう一度開いてください。")
                        return .none
                    }
                    let combined = [state.editor?.task.title ?? "", text].filter { !$0.isEmpty }.joined(separator: " ")
                    guard combined.count <= TaskInputPolicy.titleLimit
                    else { state.voice.error = L10n.tr("現在のタイトルと合わせて1,024文字以内にしてください。")
                        return .none
                    }
                    state.editor?.task.title = combined
                } else {
                    let combined = [state.aiText, text].filter { !$0.isEmpty }.joined(separator: " ")
                    guard combined.count <= TaskInputPolicy.promptLimit
                    else { state.voice.error = L10n.tr("現在の指示と合わせて1,500文字以内にしてください。")
                        return .none
                    }
                    state.aiText = combined
                    state.proposalBatch = nil
                }
                state.showsVoice = false
                return .send(.voice(.cancel))
            case .notifications(.loaded(.success)):
                return state.pendingNotificationEdits.isEmpty ? .none : .send(.processQueue)
            case let .notifications(.synchronized(revision, .success)):
                if revision == state.notifications.revision { acknowledgeSharedTasks(&state) }
                return .none
            case .checkSharedTasks:
                return receiveSharedTasks(&state)
            case let .sharePersistenceFailed(error):
                state.error = error.message
                return .none
            case .voice, .notifications, .speechSettings: return .none
            case .foreground:
                state.today = .today
                guard state.editor == nil, state.pending.isEmpty, !state.showsVoice,
                      !state.isThinking else { return .none }
                return .send(.reload)
            case .notificationTapped, .resumeNotificationNavigation, .notificationPresentationDismissed: return .none
            case let .setUsesMockAPI(enabled):
                guard enabled != state.usesMockAPI, state.canSwitchAccount else { return .none }
                state.isLoading = true
                state.error = nil
                return .run { send in
                    await send(.apiModeChanged(enabled, Result {
                        try await tasks.setUsesMockAPI(enabled)
                    }.mapError(AppFailure.init)))
                }
            case let .apiModeChanged(enabled, .success(data)):
                state.usesMockAPI = enabled
                state.showsSampleTasks = enabled
                state.pendingNotificationKey = nil
                state.waitsForNotificationDismissal = false
                state.selection = .today
                state.search = ""
                state.showsSearch = false
                state.collapsed = []
                state.deleteCandidate = nil
                state.message = nil
                return .send(.loaded(.success(data)))
            case let .apiModeChanged(_, .failure(error)):
                state.isLoading = false
                state.error = error.message
                return .none
            case let .setSampleMode(enabled):
                guard !state.isSignedIn, state.canSwitchAccount else { return .none }
                state.showsSampleTasks = enabled
                return state.pendingNotificationKey == nil ? .none : .send(.resumeNotificationNavigation)
            case .binding: return .none
            case let .displayLanguageChanged(language):
                state.$displayLanguage.withLock { $0 = language }
                state.aiUnavailable = ai.availability()
                return .none
            case .appeared:
                state.aiUnavailable = ai.availability()
                return .merge(
                    .send(.speechSettings(.load)),
                    .send(.notifications(.start)),
                    state.snapshot.lists.isEmpty ? .send(.reload) : .none,
                )
            case .reload:
                guard state.pending.isEmpty, !state.isLoading, !state.isThinking,
                      !state.showsVoice else { return .none }
                if state.editor != nil {
                    commit(&state)
                    guard state.editor == nil else { return .none }
                    if !state.pending.isEmpty {
                        state.reloadAfterWrites = true
                        return .send(.processQueue)
                    }
                }
                state.isLoading = true
                return .run { send in await send(.loaded(Result { try await tasks.load() }.mapError(AppFailure.init))) }
            case let .loaded(.success(data)):
                state.isLoading = false
                state.hasLoadedTasks = true
                let cancellation = cancelAI(&state)
                state.snapshot = data.snapshot
                state.account = data.account
                state.googleAccount = data.googleAccount
                if data.account == nil { state.showsSettings = false }
                state.error = nil
                state.proposalBatch = nil
                if case let .list(id) = state.selection,
                   !data.snapshot.lists.contains(where: { $0.id == id }) { state.selection = .today }
                return .merge(
                    cancellation,
                    receiveSharedTasks(&state),
                    state.pendingNotificationKey == nil ? .none : .send(.resumeNotificationNavigation),
                    .send(.notifications(.tasksUpdated(state.snapshot, state.account, reviewOverdue: true))),
                )
            case let .loaded(.failure(error)):
                state.isLoading = false
                state.error = error.message
                return .none
            case let .select(selection):
                guard !state.isLoading, !state.showsVoice else { return .none }
                commit(&state)
                guard state.editor == nil else { return .none }
                state.selection = selection
                state.compactColumn = .detail
                let cancellation = cancelAI(&state)
                state.search = ""
                state.proposalBatch = nil
                return .merge(.send(.processQueue), cancellation)
            case let .beginAdd(after, parent):
                guard !state.isLoading, !state.showsVoice else { return .none }
                commit(&state)
                guard state.editor == nil else { return .none }
                begin(&state, after: after, parent: parent)
                return .send(.processQueue)
            case let .edit(id):
                guard !state.isLoading, !state.showsVoice else { return .none }
                if state.showsTaskDetails { return .send(.openDetails(id)) }
                guard state.editor?.task.id != id else { return .none }
                commit(&state)
                guard state.editor == nil else { return .none }
                if let task = state.snapshot.tasks.first(where: { $0.id == id }) {
                    state.editor = TaskEditor(id: uuid().uuidString, task: task, isNew: false)
                }
                return .send(.processQueue)
            case let .openDetails(id), let .openSearchResult(id):
                guard !state.isLoading, !state.showsVoice else { return .none }
                if state.editor?.task.id == id {
                    if case .openSearchResult = action, let task = state.editor?.task {
                        state.selection = .list(task.listID)
                        state.compactColumn = .detail
                    }
                    state.showsTaskDetails = true
                    return .none
                }
                commit(&state)
                guard state.editor == nil,
                      let task = state.snapshot.tasks.first(where: { $0.id == id }) else { return .none }
                state.editor = TaskEditor(id: uuid().uuidString, task: task, isNew: false)
                if case .openSearchResult = action {
                    state.selection = .list(task.listID)
                    state.compactColumn = .detail
                }
                state.showsTaskDetails = true
                return .send(.processQueue)
            case let .saveDetails(id):
                guard state.showsTaskDetails, state.editor?.task.id == id else { return .none }
                saveDetails(&state)
                return .send(.processQueue)
            case .closeDetails:
                guard state.showsTaskDetails else { return .none }
                commit(&state)
                return .send(.processQueue)
            case let .editorTitle(text): state.editor?.task.title = text
                return .none
            case let .editorNotes(text): state.editor?.task.notes = text
                return .none
            case let .editorSchedule(id, change):
                guard !state.isLoading, !state.showsVoice, state.editor?.task.id == id else { return .none }
                updateEditorSchedule(&state, change: change)
                if state.showsTaskDetails { saveDetails(&state) }
                return .send(.processQueue)
            case let .commitEditor(continuing):
                let editor = state.editor
                let hadTitle = editor?.task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                commit(&state)
                if continuing, hadTitle, state.editor == nil {
                    begin(&state, after: editor?.task.id, parent: editor?.task.parentID, listID: editor?.task.listID)
                }
                return .send(.processQueue)
            case .cancelEditor:
                if state.showsTaskDetails {
                    commit(&state)
                    return .send(.processQueue)
                }
                if !state.writeFailed, let editor = state.editor,
                   state.error == TaskInputPolicy.error(for: editor.task)
                {
                    state.error = nil
                }
                state.editor = nil
                return state.pendingNotificationKey == nil ? .none : .send(.resumeNotificationNavigation)
            case .blankClicked:
                if state.showsTaskDetails { saveDetails(&state) }
                else { commit(&state) }
                return .send(.processQueue)
            case let .toggleComplete(id):
                guard !state.isLoading, !state.showsVoice else { return .none }
                if state.showsTaskDetails { saveDetails(&state) }
                else { commit(&state) }
                // Invalid drafts must not be bypassed by a completion action.
                if let editor = state.editor,
                   editor.task != state.snapshot.tasks.first(where: { $0.id == editor.task.id }) { return .none }
                guard let index = state.snapshot.tasks.firstIndex(where: { $0.id == id }) else { return .none }
                state.snapshot.tasks[index].isCompleted.toggle()
                let isCompleted = state.snapshot.tasks[index].isCompleted
                if state.showsTaskDetails, state.editor?.task.id == id {
                    state.editor?.task.isCompleted = isCompleted
                }
                state.pending.append(PendingWrite(task: state.snapshot.tasks[index]))
                return .send(.processQueue)
            case let .toggleChildren(id):
                if !state.collapsed.insert(id).inserted { state.collapsed.remove(id) }
                return .none
            case let .requestDelete(id):
                guard !state.isLoading, !state.showsVoice else { return .none }
                state.deleteCandidate = state.snapshot.tasks.first { $0.id == id }
                return .none
            case .swipeDelete, .confirmDelete:
                guard !state.isLoading, !state.showsVoice else { return .none }
                let taskID: String
                if case let .swipeDelete(id) = action {
                    taskID = id
                } else if let candidate = state.deleteCandidate {
                    taskID = candidate.id
                } else {
                    return .none
                }
                guard let task = state.snapshot.tasks.first(where: { $0.id == taskID }) else { return .none }
                // Swipe actions already express the deletion intent; use the same queue and
                // descendant cleanup as confirmed deletion without presenting another dialog.
                state.deleteCandidate = nil
                let removedIDs = state.snapshot.descendantIDs(of: task.id)
                let previousHead = state.pending.first?.id
                let inFlightID = state.isSaving ? previousHead : nil
                // Persist cancellation before removing the visible draft, or a failed disk write
                // could silently re-create it the next time the inbox is imported.
                let removable = removedIDs.filter { id in
                    !state.pending.contains { $0.task.id == id && $0.id == inFlightID }
                }
                do {
                    try shareInbox.remove(Set(removable))
                    state.sharedAwaitingNotification.subtract(removable)
                } catch {
                    state.error = L10n.tr("共有ToDoの保存状態を更新できませんでした。\n%@", error.localizedDescription)
                    return .none
                }
                if let editor = state.editor, removedIDs.contains(editor.task.id) {
                    state.editor = nil
                    state.showsTaskDetails = false
                }
                state.pending.removeAll { removedIDs.contains($0.task.id) && $0.id != inFlightID }
                let parentInsertInFlight = state.pending.contains { $0.task.id == task.id && !$0.isDelete }
                state.snapshot.tasks.removeAll { removedIDs.contains($0.id) }
                for id in removedIDs {
                    state.pendingNotificationEdits[id] = nil
                }
                if task.remoteID != nil || parentInsertInFlight {
                    state.pending.append(PendingWrite(task: task, isDelete: true))
                }
                if !state.isSaving, previousHead != state.pending.first?.id {
                    state.writeFailed = false
                    state.error = nil
                }
                return .send(.processQueue)
            case .processQueue:
                let notificationUpdate = Effect<Action>.merge(
                    notificationEffects(&state),
                    state.pendingNotificationKey != nil && state.editor == nil && !state.waitsForNotificationDismissal
                        ? .send(.resumeNotificationNavigation) : .none,
                )
                if state.pending.isEmpty, state.reloadAfterWrites {
                    state.reloadAfterWrites = false
                    return .merge(notificationUpdate, .send(.reload))
                }
                guard !state.isSaving, !state.writeFailed,
                      var write = state.pending.first else { return notificationUpdate }
                state.isSaving = true
                if let current = state.snapshot.tasks.first(where: { $0.id == write.task.id }) {
                    write.task.remoteID = current.remoteID
                    write.task.etag = current.etag
                }
                let previous = write.previousID.flatMap { id in state.snapshot.tasks.first {
                    $0.id == id && $0.parentID == write.task.parentID && $0.listID == write.task.listID
                }?.remoteID }
                let parent = write.task.parentID.flatMap { id in state.snapshot.tasks.first { $0.id == id }?.remoteID }
                return .merge(notificationUpdate, .run { [write] send in
                    do {
                        let saved: ReminderTask
                        if write.isDelete { try await tasks.delete(write.task)
                            try shareInbox.remove([write.task.id])
                            saved = write.task
                        } else {
                            try shareInbox.stage(write.task)
                            saved = try await tasks.save(write.task, previous, parent)
                            do { try shareInbox.receipt(saved) } catch {
                                // The server has already inserted the task. Preserve its ID even if
                                // the local receipt fails, so Retry never issues a second insertion.
                                await send(.writeFinished(write.id, .success(saved)))
                                await send(.sharePersistenceFailed(AppFailure(error)))
                                return
                            }
                        }
                        await send(.writeFinished(write.id, .success(saved)))
                    } catch { await send(.writeFinished(write.id, .failure(AppFailure(error)))) }
                })
            case let .writeFinished(id, .success(task)):
                guard state.pending.first?.id == id else { return .none }
                state.pending.removeFirst()
                state.isSaving = false
                if task.id.hasPrefix("share-"), state.snapshot.tasks.contains(where: { $0.id == task.id }) {
                    state.sharedAwaitingNotification.insert(task.id)
                }
                if let index = state.snapshot.tasks.firstIndex(where: { $0.id == task.id }) {
                    state.snapshot.tasks[index].remoteID = task.remoteID
                    state.snapshot.tasks[index].etag = task.etag
                }
                // Propagate remote identity to every queued edit/delete, including deleted rows.
                for index in state.pending.indices where state.pending[index].task.id == task.id {
                    state.pending[index].task.remoteID = task.remoteID
                    state.pending[index].task.etag = task.etag
                }
                if state.editor?.task.id == task.id {
                    state.editor?.task.remoteID = task.remoteID
                    state.editor?.task.etag = task.etag
                }
                if state.pending.isEmpty { state.message = L10n.tr("保存しました") }
                return .send(.processQueue)
            case let .writeFinished(id, .failure(error)):
                guard let write = state.pending.first, write.id == id else { return .none }
                state.isSaving = false
                if !write.isDelete, !state.snapshot.tasks.contains(where: { $0.id == write.task.id }) {
                    state.pending.removeFirst()
                    state.pending.removeAll { $0.task.id == write.task.id && $0.task.remoteID == nil }
                    return .send(.processQueue)
                }
                state.writeFailed = true
                state.error = L10n.tr("保存できませんでした。入力は保持されています。\n%@", String(describing: error.message))
                return .none
            case .retryWrites:
                state.writeFailed = false
                state.error = nil
                return .send(.processQueue)
            case .dismissError: state.error = nil
                return .none
            case .addList:
                let title = state.newListTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, !state.isLoading, !state.showsVoice, !state.isThinking else { return .none }
                commit(&state)
                guard state.editor == nil, state.pending.isEmpty else { return .send(.processQueue) }
                guard title.count <= TaskInputPolicy.titleLimit else { state.error = L10n.tr("リスト名は1,024文字以内にしてください。")
                    return .none
                }
                let appearance = state.newListAppearance.validated
                state.isLoading = true
                state.error = nil
                return .run { send in
                    await send(.listAdded(Result { try await tasks.addList(title, appearance) }
                            .mapError(AppFailure.init)))
                }
            case let .listAdded(.success(list)):
                state.isLoading = false
                state.snapshot.lists.append(list)
                state.selection = .list(list.id)
                state.showsNewList = false
                state.newListTitle = ""
                state.newListAppearance = ListAppearance()
                state.compactColumn = .detail
                return state.pendingNotificationKey == nil ? .none : .send(.resumeNotificationNavigation)
            case let .listAdded(.failure(error)):
                state.isLoading = false
                state.error = error.message
                return state.pendingNotificationKey == nil ? .none : .send(.resumeNotificationNavigation)
            case .signInCancelled:
                state.isLoading = false
                state.error = nil
                return .none
            case .connect, .disconnect, .signInAccount, .signOutAccount:
                guard state.canSwitchAccount else { return .none }
                let managesAccount = action.is(\.signInAccount) || action.is(\.signOutAccount)
                if state.usesMockAPI, !managesAccount {
                    state.showsSampleTasks = true
                    return .send(.reload)
                }
                state.isLoading = true
                state.error = nil
                let connect = action.is(\.connect) || action.is(\.signInAccount)
                return .run { send in
                    do {
                        let data: ConnectedTasks = if managesAccount {
                            try await connect ? tasks.signInAccount() : tasks.signOutAccount()
                        } else {
                            try await connect ? tasks.connect() : tasks.disconnect()
                        }
                        await send(.loaded(.success(data)))
                    } catch {
                        let nsError = error as NSError
                        if connect, nsError.domain == kGIDSignInErrorDomain,
                           nsError.code == GIDSignInError.canceled.rawValue
                        {
                            await send(.signInCancelled)
                        } else {
                            await send(.loaded(.failure(AppFailure(error))))
                        }
                    }
                }
            case .askAI, .aiResult, .showExample, .cancelProposal, .applyProposal: return .none
            }
        }
    }

    private func begin(_ state: inout State, after: String?, parent: String?, listID: String? = nil) {
        let anchor = (parent ?? after).flatMap { id in state.snapshot.tasks.first { $0.id == id } }
        if parent != nil, anchor == nil || anchor?.parentID != nil { return }
        guard let listID = listID ?? anchor?.listID ?? state.defaultListID else {
            state.showsNewList = true
            return
        }
        let id = uuid().uuidString
        let due: TaskDay? = state.selection == .today ? state.today : nil
        let task = ReminderTask(id: id, listID: listID, title: "", due: due, parentID: parent)
        let previous = after ?? state.snapshot.tasks.last { $0.listID == listID && $0.parentID == parent }?.id
        state.editor = TaskEditor(id: id, task: task, isNew: true, afterID: previous)
    }

    func commit(_ state: inout State) {
        guard var editor = state.editor else { return }
        editor.task.title = editor.task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editor.task.title.isEmpty else {
            if state.showsTaskDetails || !editor.isNew {
                state.error = L10n.tr("タイトルを入力してください。")
                return
            }
            state.editor = nil
            return
        }
        guard TaskInputPolicy.error(for: editor.task) == nil else {
            state.error = TaskInputPolicy.error(for: editor.task)
            return
        }
        state.editor = nil
        state.showsTaskDetails = false
        if !state.writeFailed { state.error = nil }
        if let edit = editor.notificationEdit { state.pendingNotificationEdits[editor.task.id] = edit }
        if editor.isNew {
            let index = editor.afterID.flatMap { id in state.snapshot.tasks.firstIndex { $0.id == id } }
                .map { $0 + 1 } ?? state.snapshot.tasks.count
            state.snapshot.tasks.insert(editor.task, at: index)
            state.pending.append(PendingWrite(task: editor.task, previousID: editor.afterID))
        } else if let index = state.snapshot.tasks.firstIndex(where: { $0.id == editor.task.id }),
                  state.snapshot.tasks[index] != editor.task
        {
            state.snapshot.tasks[index] = editor.task
            state.pending.append(PendingWrite(task: editor.task))
        }
    }

    /// Commit through the same queue as inline input without replacing the detail's identity/focus.
    private func saveDetails(_ state: inout State) {
        guard state.showsTaskDetails, let editor = state.editor else { return }
        commit(&state)
        guard state.editor == nil,
              let saved = state.snapshot.tasks.first(where: { $0.id == editor.task.id }) else { return }
        state.editor = TaskEditor(id: editor.id, task: saved, isNew: false)
        state.showsTaskDetails = true
    }
}
