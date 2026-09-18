import ComposableArchitecture

extension AppFeature {
    func reduceNotificationNavigation(into state: inout State, action: Action) -> Effect<Action>? {
        switch action {
        case let .notificationTapped(key):
            state.pendingNotificationKey = key
            if NotificationRouting.isSampleTask(key), !state.showsSampleTasks {
                state.pendingNotificationKey = nil
                return .none
            }
            guard state.canNavigateToTasks else { return .none }
            // A sheet's onDismiss resumes navigation after its dismissal animation.
            var dismissingSheet = state.showsSettings || state.showsNewList || state.showsVoice
                || state.accountMenuSource != nil
                || (!state.notifications.conflicts.isEmpty && !state.showsTaskDetails)
            state.showsSettings = false
            state.accountMenuSource = nil
            state.showsNewList = false
            state.deleteCandidate = nil
            #if DEBUG
                dismissingSheet = dismissingSheet || state.showsDebug
                state.showsDebug = false
            #endif
            state.waitsForNotificationDismissal = dismissingSheet
            if state.showsVoice { return .send(.closeVoice) }
            return dismissingSheet ? .none : .send(.resumeNotificationNavigation)

        case .notificationPresentationDismissed:
            state.waitsForNotificationDismissal = false
            return state.pendingNotificationKey == nil ? .none : .send(.resumeNotificationNavigation)

        case .resumeNotificationNavigation:
            if let key = state.pendingNotificationKey,
               NotificationRouting.isSampleTask(key), !state.showsSampleTasks
            {
                state.pendingNotificationKey = nil
                return .none
            }
            guard state.canNavigateToTasks else { return .none }
            guard let key = state.pendingNotificationKey, !state.isLoading, !state.waitsForNotificationDismissal,
                  state.accountMenuSource == nil,
                  !state.showsSettings, !state.showsNewList, !state.showsVoice else { return .none }
            #if DEBUG
                guard !state.showsDebug else { return .none }
            #endif
            guard state.hasLoadedTasks || !state.snapshot.lists.isEmpty else { return .send(.reload) }
            let scope = NotificationPlanner.scope(state.account)
            guard let task = state.snapshot.tasks
                .first(where: { NotificationPlanner.key(task: $0, scope: scope) == key })
            else {
                state.pendingNotificationKey = nil
                state.error = L10n.tr("通知のタスクが見つかりません。削除済み、または別のアカウントのタスクです。")
                return .none
            }
            if state.editor?.task.id != task.id {
                commit(&state)
                // Keep invalid drafts intact; resume after the user corrects or closes them.
                guard state.editor == nil else { return .none }
            }
            state.pendingNotificationKey = nil
            state.showsSearch = false
            state.search = ""
            return .merge(cancelAI(&state), .send(.openSearchResult(task.id)))

        default: return nil
        }
    }
}
