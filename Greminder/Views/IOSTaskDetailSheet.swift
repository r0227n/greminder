#if os(iOS)
    import ComposableArchitecture
    import SwiftUI

    struct IOSTaskDetailSheet: View {
        @Environment(\.locale) private var locale
        @Bindable var store: StoreOf<AppFeature>
        @FocusState private var field: String?

        private var task: ReminderTask? { store.editor?.task }
        private var accent: Color { AppTheme.tint(.list(task?.listID ?? ""), lists: store.snapshot.lists) }
        private var canDismiss: Bool {
            guard let task else { return true }
            return TaskInputPolicy.error(for: task) == nil
        }

        var body: some View {
            NavigationStack {
                Form {
                    if let error = store.error {
                        Section {
                            Text(error).foregroundStyle(.red)
                            if store.writeFailed { Button(L10n.tr("保存を再試行")) { store.send(.retryWrites) } }
                        }.accessibilityIdentifier("task-detail-error")
                    }
                    if let task {
                        Section {
                            VStack(alignment: .leading, spacing: 18) {
                                TextField(L10n.tr("タイトル"), text: Binding(
                                    get: { self.task?.title ?? "" }, set: { store.send(.editorTitle($0)) },
                                ), axis: .vertical)
                                    .font(.title2.weight(.semibold)).foregroundStyle(.primary)
                                    .focused($field, equals: task.id + ".title")
                                    .onSubmit { store.send(.saveDetails(task.id)) }
                                    .accessibilityLabel(L10n.tr("詳細のタイトル")).accessibilityIdentifier("task-detail-title")
                                TextField(L10n.tr("メモ"), text: Binding(
                                    get: { self.task?.notes ?? "" }, set: { store.send(.editorNotes($0)) },
                                ), axis: .vertical)
                                    .lineLimit(1 ... 8)
                                    .focused($field, equals: task.id + ".notes")
                                    .accessibilityLabel(L10n.tr("詳細のメモ")).accessibilityIdentifier("task-detail-notes")
                            }.padding(.vertical, 8)
                        }
                        TaskScheduleSection(store: store, onInteraction: { field = nil }).id(task.id)
                        Section(L10n.tr("整理")) {
                            LabeledContent {
                                Text(store.snapshot.lists.first { $0.id == task.listID }?.title ?? "")
                            } label: { Label {
                                Text(L10n.tr("リスト")).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: store.snapshot.lists.first { $0.id == task.listID }?
                                    .symbol ?? "list.bullet")
                                    .font(.caption).foregroundStyle(.white)
                                    .frame(width: 26, height: 26).background(accent, in: Circle())
                            } }
                            Toggle(L10n.tr("完了済み"), isOn: Binding(
                                get: { self.task?.isCompleted ?? false },
                                set: { _ in store.send(.toggleComplete(task.id)) },
                            ))
                            if let parentID = task.parentID,
                               let parent = store.snapshot.tasks.first(where: { $0.id == parentID })
                            {
                                Button { store.send(.openDetails(parentID)) } label: {
                                    rowLabel(parent.title, symbol: "arrow.turn.up.left", color: accent)
                                }.buttonStyle(.plain)
                            }
                        }
                        if task.parentID == nil {
                            let children = store.snapshot.tasks.filter { $0.parentID == task.id }
                            Section(L10n.tr("サブタスク（%@）", String(describing: children.count))) {
                                ForEach(children) { child in
                                    HStack {
                                        TaskCompletionButton(
                                            title: child.title,
                                            isCompleted: child.isCompleted,
                                            accent: accent,
                                        ) {
                                            store.send(.toggleComplete(child.id))
                                        }
                                        Button { store.send(.openDetails(child.id)) } label: {
                                            HStack {
                                                Text(child.title).strikethrough(child.isCompleted)
                                                    .foregroundStyle(.primary)
                                                Spacer()
                                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(L10n.tr("%@の詳細", child.title))
                                    }
                                }
                                Button { store.send(.beginAdd(after: children.last?.id ?? task.id, parent: task.id))
                                } label: {
                                    rowLabel(L10n.tr("サブタスクを追加"), symbol: "plus", color: accent)
                                }.buttonStyle(.plain)
                            }
                        }
                        Section {
                            Button(L10n.tr("タスクを削除"), role: .destructive) { store.send(.requestDelete(task.id)) }
                        }
                    }
                }
                .navigationTitle(L10n.tr("詳細"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { store.send(.closeDetails) } label: {
                            Image(systemName: "xmark").foregroundStyle(.primary)
                        }
                        .tint(.primary)
                        .accessibilityLabel(L10n.tr("詳細を閉じる"))
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { store.send(.closeDetails) } label: { Image(systemName: "checkmark") }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                            .accessibilityLabel(L10n.tr("変更を確定")).accessibilityIdentifier("task-detail-done")
                    }
                }
            }
            .tint(accent)
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(!canDismiss)
            .onChange(of: field) { old, _ in
                if let old, let task, old.hasPrefix(task.id + ".") { store.send(.saveDetails(task.id)) }
            }
            .sheet(isPresented: $store.showsSettings, onDismiss: { store.send(.notificationPresentationDismissed) }) {
                SettingsView(store: store).tint(AppTheme.blue)
            }
            .confirmationDialog(L10n.tr("このタスクを削除しますか？サブタスクも削除されます。"), isPresented: Binding(
                get: { store.deleteCandidate != nil }, set: { if !$0 { store.deleteCandidate = nil } },
            ), titleVisibility: .visible) {
                Button(L10n.tr("削除"), role: .destructive) { store.send(.confirmDelete) }
            }
        }

        private func rowLabel(_ title: String, symbol: String, color: Color) -> some View {
            Label { Text(title).foregroundStyle(.primary) } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
        }
    }
#endif
