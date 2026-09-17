#if DEBUG
    import ComposableArchitecture
    import SwiftUI
    import UserNotifications

    struct DebugToolsButton: View {
        @Bindable var store: StoreOf<AppFeature>

        var body: some View {
            Button { store.showsDebug = true } label: {
                Label(L10n.tr("デバッグ"), systemImage: "ladybug")
            }
            .help(L10n.tr("デバッグ"))
            .accessibilityIdentifier("debug-tools-open")
        }
    }

    struct DebugToolsView: View {
        let store: StoreOf<AppFeature>
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                List {
                    Section(L10n.tr("機能のデバッグ")) {
                        NavigationLink {
                            DebugNotificationsView(store: store)
                        } label: {
                            Label(L10n.tr("Push通知"), systemImage: "bell.badge")
                        }
                        .accessibilityIdentifier("debug-notifications-open")
                    }
                }
                .navigationTitle(L10n.tr("デバッグ"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.tr("閉じる")) { dismiss() }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 420)
            #endif
        }
    }

    private struct DebugNotificationsView: View {
        @Bindable var store: StoreOf<AppFeature>
        @State private var selectedTaskID = ""
        @State private var delay = 15
        private let notificationID = "greminder.manual.notification"
        enum Operation { case refresh, authorize, schedule, cancel }

        @Environment(\.scenePhase) private var scenePhase
        @State private var access: NotificationAccess?
        @State private var scheduledDate: Date?
        @State private var operation: Operation? = .refresh
        @State private var message: String?
        @State private var error: String?

        var body: some View {
            Form {
                Section(L10n.tr("遷移の状態")) {
                    LabeledContent(L10n.tr("ログイン状態"), value: store.isSignedIn ? L10n.tr("接続済み") : L10n.tr("未ログイン"))
                    LabeledContent(
                        L10n.tr("通知の遷移"),
                        value: store.pendingNotificationKey == nil ? L10n.tr("保留なし") : L10n.tr("保留中"),
                    )
                    .accessibilityIdentifier("debug-pending-navigation")
                    LabeledContent(L10n.tr("編集中のタスク"), value: store.editor == nil ? L10n.tr("なし") : L10n.tr("あり"))
                    Toggle(L10n.tr("サンプルホームを表示"), isOn: Binding(
                        get: { store.showsSampleTasks },
                        set: { store.send(.setSampleMode($0)) },
                    ))
                    .disabled(store.isSignedIn || !store.canSwitchAccount)
                    .accessibilityIdentifier("debug-sample-mode")
                    Text(L10n.tr("未ログインでの確認: タスクの通知を予約し、サンプルホームをオフにして画面を閉じ、届いた通知をタップします。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("通知の状態")) {
                    Text(access?.label ?? L10n.tr("読み込み中…"))
                    if let date = scheduledDate {
                        LabeledContent(L10n.tr("テスト通知の予約時刻")) {
                            Text(date, style: .time)
                        }
                    } else {
                        Text(L10n.tr("テスト通知の予約はありません"))
                            .foregroundStyle(.secondary)
                    }
                    Button(L10n.tr("状態を更新")) { operation = .refresh }
                        .accessibilityIdentifier("debug-notifications-refresh")
                    Button(L10n.tr("通知の許可をリクエスト")) { operation = .authorize }
                        .accessibilityIdentifier("debug-notifications-authorize")
                }
                Section {
                    Picker(L10n.tr("通知に紐づけるタスク"), selection: $selectedTaskID) {
                        Text(L10n.tr("タスクを選択")).tag("")
                        ForEach(store.snapshot.tasks) { task in
                            Text(task.title).tag(task.id)
                        }
                    }
                    .accessibilityIdentifier("debug-notification-task")
                    Text(L10n.tr("通知をタップすると、選択したタスクの詳細が開きます。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Picker(L10n.tr("通知までの秒数"), selection: $delay) {
                        ForEach([5, 15, 30, 60], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .accessibilityIdentifier("debug-notification-delay")
                    Button(L10n.tr("通知を予約")) { operation = .schedule }
                        .disabled(access != .authorized || selectedTaskID.isEmpty)
                        .accessibilityIdentifier("debug-notifications-schedule")
                    Button(L10n.tr("テスト通知をキャンセル")) { operation = .cancel }
                        .accessibilityIdentifier("debug-notifications-cancel")
                    if operation != nil { ProgressView() }
                    if let message { Text(message).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red) }
                } header: {
                    Text(L10n.tr("通知の動作確認"))
                } footer: {
                    Text(L10n.tr("端末内のローカル通知を送信します。予約後にアプリをバックグラウンドにすると、バックグラウンドでの通知を確認できます。APNs経由のリモートPush通知は対象外です。"))
                }
                Section(L10n.tr("編集と取消の確認")) {
                    Text(L10n.tr("通知を予約した後、新規タスクのタイトルに1,025文字以上入力してください。通知をタップすると入力が保持され、編集を取り消すと通知先へ遷移します。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("新規タスクを編集")) { store.send(.beginAdd(after: nil, parent: nil)) }
                        .disabled(!store.canNavigateToTasks || store.editor != nil || store.isLoading)
                        .accessibilityIdentifier("debug-begin-edit")
                    if let editor = store.editor, !store.showsTaskDetails {
                        TextField(L10n.tr("タイトル"), text: Binding(
                            get: { store.editor?.task.title ?? "" },
                            set: { store.send(.editorTitle($0)) },
                        ), axis: .vertical)
                            .lineLimit(2 ... 4)
                            .accessibilityIdentifier("debug-editor-title")
                        Text(L10n.tr("入力文字数: %@", String(editor.task.title.count)))
                            .accessibilityIdentifier("debug-editor-count")
                        Button(L10n.tr("編集を取り消して閉じる")) {
                            store.send(.cancelEditor)
                            store.showsDebug = false
                        }
                        .accessibilityIdentifier("debug-cancel-edit")
                    }
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.tr("Push通知"))
            .disabled(operation != nil)
            .task(id: operation) {
                guard let operation else { return }
                await perform(operation)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, operation == nil { operation = .refresh }
            }
        }

        @MainActor
        private func perform(_ action: Operation) async {
            error = nil
            message = nil
            let system = LocalNotificationSystem.shared
            do {
                switch action {
                case .refresh: break
                case .authorize:
                    _ = try await system.requestAccess()
                case .schedule:
                    guard let task = store.snapshot.tasks.first(where: { $0.id == selectedTaskID }) else {
                        operation = nil
                        return
                    }
                    let request = ScheduledTaskNotification(
                        id: notificationID,
                        title: task.title,
                        listTitle: store.snapshot.lists.first { $0.id == task.listID }?.title ?? L10n.tr("タスク"),
                        date: Date().addingTimeInterval(TimeInterval(delay)),
                        taskKey: NotificationPlanner.key(task: task, scope: NotificationPlanner.scope(store.account)),
                    )
                    try await system.schedule(request)
                    message = L10n.tr("通知を予約しました。%@秒後に通知されます。", String(delay))
                case .cancel:
                    system.cancelRequests(withIdentifiers: [notificationID])
                    message = L10n.tr("テスト通知をキャンセルしました。")
                }
            } catch {
                self.error = error.localizedDescription
            }
            access = await system.access()
            let request = await system.pendingRequests().first { $0.identifier == notificationID }
            scheduledDate = (request?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            operation = nil
        }
    }
#endif
