import ComposableArchitecture
import SwiftUI

/// Desktop keeps its trailing column; iOS presents the same task in a modal editor.
struct TaskDetailLayout: View {
    @Environment(\.locale) private var locale
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        #if os(macOS)
            columns
        #else
            TaskListView(store: store)
                .sheet(isPresented: Binding(
                    get: { store.showsTaskDetails },
                    set: { if !$0 { store.send(.closeDetails) } },
                )) {
                    IOSTaskDetailSheet(store: store)
                }
        #endif
    }

    private var columns: some View {
        HStack(spacing: 0) {
            TaskListView(store: store).frame(maxWidth: .infinity)
            if store.showsTaskDetails {
                Divider()
                detail.frame(width: 340)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let editor = store.editor, store.showsTaskDetails {
            TaskDetailView(store: store, taskID: editor.task.id).id(editor.task.id)
        }
    }
}

struct TaskDetailView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: StoreOf<AppFeature>
    let taskID: String
    @FocusState private var field: Field?
    private enum Field: Hashable { case title, notes }

    private var task: ReminderTask? {
        guard store.editor?.task.id == taskID else { return nil }
        return store.editor?.task
    }

    private var accent: Color { AppTheme.tint(.list(task?.listID ?? ""), lists: store.snapshot.lists) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("タスクの詳細")).font(.headline).foregroundStyle(accent)
                Spacer()
                Button(L10n.tr("完了")) { store.send(.closeDetails) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("task-detail-done")
                Button { store.send(.closeDetails) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(accent).padding(5).help(L10n.tr("詳細を閉じる"))
                    .accessibilityLabel(L10n.tr("詳細を閉じる"))
            }.padding(18)
            Divider()
            if let error = store.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    if store.writeFailed { Button(L10n.tr("保存を再試行")) { store.send(.retryWrites) } }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(Color.red.opacity(0.06))
                .accessibilityIdentifier("task-detail-error")
            }
            if let task {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        titleAndNotes(task)
                        dateSection(task)
                        organization(task)
                        subtasks(task)
                        HStack(spacing: 6) {
                            Image(systemName: store.writeFailed ? "exclamationmark.circle" : "checkmark.circle")
                            Text(store.writeFailed ? L10n.tr("未保存の変更があります") : store.isSaving ? L10n.tr("保存中…") : L10n
                                .tr("変更は自動的に保存されます"))
                        }.font(.caption).foregroundStyle(.secondary)
                        Button(L10n.tr("タスクを削除"), role: .destructive) { store.send(.requestDelete(taskID)) }
                            .buttonStyle(.borderless)
                    }.padding(18)
                }
            }
        }
        .background(AppTheme.surface)
        .tint(accent)
        .accessibilityIdentifier("task-detail-panel")
        .onChange(of: field) { old, _ in
            if old != nil { store.send(.saveDetails(taskID)) }
        }
        #if os(macOS)
        .onExitCommand { store.send(.closeDetails) }
        #endif
    }

    private func titleAndNotes(_ task: ReminderTask) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(L10n.tr("タイトル"), text: Binding(
                get: { self.task?.title ?? "" }, set: { store.send(.editorTitle($0)) },
            ), axis: .vertical)
                .font(.title2.weight(.semibold)).foregroundStyle(accent).textFieldStyle(.plain)
                .focused($field, equals: .title).onSubmit { store.send(.saveDetails(taskID)) }
                .accessibilityLabel(L10n.tr("詳細のタイトル")).accessibilityIdentifier("task-detail-title")
            Divider()
            Text(L10n.tr("メモ")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { self.task?.notes ?? "" }, set: { store.send(.editorNotes($0)) },
            ))
            .font(.body).scrollContentBackground(.hidden).frame(minHeight: 100)
            .focused($field, equals: .notes)
            .accessibilityLabel(L10n.tr("詳細のメモ")).accessibilityIdentifier("task-detail-notes")
            Toggle(L10n.tr("完了済み"), isOn: Binding(
                get: { self.task?.isCompleted ?? task.isCompleted },
                set: { _ in store.send(.toggleComplete(taskID)) },
            )).toggleStyle(.switch)
        }
    }

    private func dateSection(_ task: ReminderTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L10n.tr("日付と通知"))
            Toggle(isOn: Binding(
                get: { self.task?.due != nil },
                set: { setDate($0 ? store.today : nil) },
            )) { Label(L10n.tr("日付"), systemImage: "calendar") }
                .toggleStyle(.switch).accessibilityIdentifier("task-detail-has-date")
            if task.due != nil {
                DatePicker(L10n.tr("予定日"), selection: Binding(
                    get: { self.task?.due?.date ?? store.today.date },
                    set: { setDate(TaskDay(date: $0)) },
                ), displayedComponents: .date)
                    .datePickerStyle(.compact)
                if store.notifications.preferences.enabled,
                   let date = store.editorNotificationDate
                {
                    DatePicker(L10n.tr("端末の通知"), selection: Binding(
                        get: { store.editorNotificationDate ?? date },
                        set: { store.send(.editorSchedule(task.id, .time($0))) },
                    ), displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                    Text(L10n.tr("通知時刻はこの端末に保存されます。Google Tasksとは予定日のみ同期します。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(L10n.tr("通知を設定…")) { store.showsSettings = true }.buttonStyle(.borderless)
                }
            }
            if let error = store.notifications.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func organization(_ task: ReminderTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L10n.tr("整理"))
            LabeledContent(L10n.tr("リスト"), value: store.snapshot.lists.first { $0.id == task.listID }?.title ?? "")
            if let parentID = task.parentID,
               let parent = store.snapshot.tasks.first(where: { $0.id == parentID })
            {
                Button { store.send(.openDetails(parentID)) } label: {
                    Label(parent.title, systemImage: "arrow.turn.up.left")
                }.buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private func subtasks(_ task: ReminderTask) -> some View {
        if task.parentID == nil {
            let children = store.snapshot.tasks.filter { $0.parentID == taskID }
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(L10n.tr("サブタスク（%@）", String(describing: children.count)))
                ForEach(children) { child in
                    HStack(spacing: 10) {
                        Button { store.send(.toggleComplete(child.id)) } label: {
                            Image(systemName: child.isCompleted ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.plain).accessibilityLabel(L10n.tr(
                            "%@の完了を切り替える",
                            String(describing: child.title),
                        ))
                        Button { store.send(.openDetails(child.id)) } label: {
                            HStack {
                                Text(child.title).strikethrough(child.isCompleted)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(L10n.tr("%@の詳細", String(describing: child.title)))
                    }
                }
                Button { store.send(.beginAdd(after: children.last?.id ?? taskID, parent: taskID)) } label: {
                    Label(L10n.tr("サブタスクを追加"), systemImage: "plus")
                }.buttonStyle(.borderless)
            }
        }
    }

    private func setDate(_ day: TaskDay?) {
        store.send(.editorSchedule(taskID, .date(day)))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
