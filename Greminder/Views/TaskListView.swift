import ComposableArchitecture
import SwiftUI

struct TaskListView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: StoreOf<AppFeature>
    @FocusState private var focusedEditor: String?
    #if os(iOS)
        @Environment(\.horizontalSizeClass) var horizontalSizeClass
    #endif

    private var accent: Color { AppTheme.tint(store.selection, lists: store.snapshot.lists) }

    private var horizontalPadding: CGFloat {
        #if os(macOS)
            28
        #else
            20
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error { errorBanner(error) }
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            if store.isLoading && store.snapshot.lists.isEmpty {
                                ProgressView(L10n.tr("読み込み中…")).frame(maxWidth: .infinity).padding(35)
                            }
                            ForEach(store.visibleTasks) { task in
                                taskRow(task)
                                if let editor = store.editor, editor.isNew, editor.afterID == task.id {
                                    editorRow(editor)
                                }
                            }
                            if let editor = store.editor, editor.isNew,
                               editor.afterID == nil || !store.visibleTasks
                               .contains(where: { $0.id == editor.afterID })
                            {
                                editorRow(editor)
                            }
                            if store.visibleTasks.isEmpty, store.editor == nil, !store.isLoading {
                                VStack(spacing: 10) {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(
                                            size: 36,
                                            weight: .light,
                                        )).foregroundStyle(.tertiary)
                                    Text(L10n.tr(
                                        "%@のタスクはありません",
                                        String(describing: store.title),
                                    ))
                                    .font(.callout).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.top, 30)
                            }
                            blankArea.frame(minHeight: store.proposals.isEmpty ? 90 : 16)
                                .frame(maxHeight: .infinity)
                            if !store.proposals.isEmpty {
                                ProposalPreview(store: store).padding(.top, 14).padding(.bottom, 16)
                                    .id("proposal-preview")
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, 88)
                        .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                .onChange(of: store.editor?.id) { _, id in
                    if id == nil { focusedEditor = nil }
                    if let id { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) } }
                }
                .onChange(of: store.proposals.map(\.id)) { _, ids in
                    if !ids.isEmpty {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("proposal-preview", anchor: .bottom)
                        }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                FloatingAddButton(title: L10n.tr("タスクを追加"), color: accent, identifier: "task-add-fab") {
                    store.send(.beginAdd(after: nil, parent: nil))
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(store.snapshot.lists.isEmpty || store.showsVoice)
                .padding(.horizontal, horizontalPadding).padding(.bottom, 16)
            }
            if store.showsAIComposer {
                AIComposerView(store: store)
                    .padding(.horizontal, horizontalPadding).padding(.top, 8).padding(.bottom, 12)
            }
        }
        .background(AppTheme.surface)
        .onDisappear { focusedEditor = nil }
        .onChange(of: store.showsVoice) { _, visible in
            focusedEditor = visible ? nil : store.voice.destination == .task ? store.editor?.id : nil
        }
        .navigationTitle("")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    #if DEBUG
                        DebugToolsButton(store: store)
                    #endif
                    Button { store.send(.openVoice(.task)) } label: { Image(systemName: "mic") }
                        .help(L10n.tr("音声でタスクを入力")).accessibilityLabel(L10n.tr("音声でタスクを入力"))
                        .disabled(store.showsVoice)
                    Button { store.showsAIComposer.toggle() } label: {
                        Image(systemName: "sparkles")
                            .frame(width: 24, height: 24)
                            .overlay {
                                if !store.showsAIComposer {
                                    Image(systemName: "line.diagonal")
                                        .font(.system(size: 25, weight: .bold))
                                        .foregroundStyle(accent)
                                        .background {
                                            Image(systemName: "line.diagonal")
                                                .font(.system(size: 25, weight: .black))
                                                .foregroundStyle(AppTheme.surface)
                                                .scaleEffect(1.08)
                                        }
                                }
                            }
                            .padding(5)
                            .background(store.showsAIComposer ? accent.opacity(0.12) : .clear, in: Circle())
                    }
                    .help(store.showsAIComposer ? L10n.tr("AI入力欄を隠す") : L10n.tr("AI入力欄を表示"))
                    .accessibilityLabel(store.showsAIComposer ? L10n.tr("AI入力欄を隠す") : L10n.tr("AI入力欄を表示"))
                    .accessibilityAddTraits(store.showsAIComposer ? .isSelected : [])
                    .accessibilityIdentifier("ai-composer-toggle")
                    Menu {
                        Button(L10n.tr("再読み込み"), systemImage: "arrow.clockwise") { store.send(.reload) }
                            .disabled(!store.pending.isEmpty)
                        Button(L10n.tr("設定"), systemImage: "gearshape") { store.showsSettings = true }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel(L10n.tr("その他"))
                }
            }
            .tint(accent)
        #if os(macOS)
            .onExitCommand { store.send(.cancelEditor) }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.title).font(.system(size: 38, weight: .bold)).foregroundStyle(accent)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(store.visibleCount)").font(.system(size: 28, weight: .light))
                    .foregroundStyle(accent)
            }
            Text(store.selection == .today ? store.today.date
                .formatted(.dateTime.month(.defaultDigits).day().weekday(.wide).locale(L10n.locale)) :
                store.account == nil ? L10n.tr("サンプルデータ") : "Google Tasks")
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }.padding(.top, 14).padding(.bottom, 21)
    }

    @ViewBuilder private var blankArea: some View {
        let area = Rectangle().fill(.clear).contentShape(Rectangle())
        #if os(macOS)
            area.onTapGesture(count: 2) { store.send(.beginAdd(after: nil, parent: nil)) }
                .onTapGesture { store.send(.blankClicked) }
                .accessibilityLabel(L10n.tr("タスク一覧の余白"))
                .accessibilityAction(named: L10n.tr("タスクを追加")) { store.send(.beginAdd(after: nil, parent: nil)) }
        #else
            area.onTapGesture { store.send(.beginAdd(after: nil, parent: nil)) }
                .accessibilityLabel(L10n.tr("タップしてタスクを追加"))
                .accessibilityAddTraits(.isButton)
        #endif
    }

    @ViewBuilder private func taskRow(_ task: ReminderTask) -> some View {
        if let editor = store.editor, !store.showsTaskDetails, !editor.isNew,
           editor.task.id == task.id { editorRow(editor) }
        else {
            HStack(alignment: .top, spacing: 12) {
                completionButton(task)
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title).font(.system(size: rowFontSize)).strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !task.notes
                        .isEmpty { Text(task.notes).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                    HStack(spacing: 6) {
                        if task
                            .parentID == nil { Text(store.snapshot.lists.first { $0.id == task.listID }?.title ?? "") }
                        if let due = task.due, store.selection != .today {
                            Text(due.label)
                                .foregroundStyle(due < store.today && !task.isCompleted ? Color.red : Color.secondary)
                        }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { store.send(.edit(task.id)) }
                .accessibilityAction(named: L10n.tr("編集")) { store.send(.edit(task.id)) }
                Button { store.send(.openDetails(task.id)) } label: {
                    Image(systemName: "info.circle").font(.system(size: 16)).padding(5)
                }
                .buttonStyle(.plain).foregroundStyle(accent)
                .help(L10n.tr("詳細を表示")).accessibilityLabel(L10n.tr("%@の詳細", String(describing: task.title)))
                .accessibilityIdentifier("task-details-\(task.id)")
                if store.snapshot.tasks.contains(where: { $0.parentID == task.id }) {
                    Button { store.send(.toggleChildren(task.id)) } label: {
                        Image(systemName: store.collapsed.contains(task.id) ? "chevron.right" : "chevron.down")
                            .font(.system(
                                size: 11,
                                weight: .semibold,
                            ))
                    }.buttonStyle(.plain).padding(5).accessibilityLabel(L10n.tr("サブタスクの表示を切り替える"))
                }
            }
            .padding(.leading, task.parentID == nil ? 0 : 30)
            .padding(.vertical, 14)
            .background(
                store.showsTaskDetails && store.editor?.task.id == task.id ? AppTheme.subtle : .clear,
                in: RoundedRectangle(cornerRadius: 8),
            )
            .overlay(alignment: .bottom) { Divider().padding(.leading, task.parentID == nil ? 35 : 65).opacity(0.6) }
            .contextMenu {
                Button(L10n.tr("編集")) { store.send(.edit(task.id)) }
                Button(L10n.tr("詳細"), systemImage: "info.circle") { store.send(.openDetails(task.id)) }
                Button(L10n.tr("下にタスクを追加")) { store.send(.beginAdd(after: task.id, parent: task.parentID)) }
                if task
                    .parentID == nil { Button(L10n.tr("サブタスクを追加")) { store.send(.beginAdd(
                        after: task.id,
                        parent: task.id,
                    )) } }
                Button(L10n.tr("削除"), role: .destructive) { store.send(.requestDelete(task.id)) }
            }
        }
    }

    private var rowFontSize: CGFloat {
        #if os(macOS)
            15
        #else
            17
        #endif
    }

    private func editorRow(_ editor: TaskEditor) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle").font(.system(size: 22, weight: .ultraLight)).foregroundStyle(.secondary)
                .padding(
                    .top,
                    2,
                )
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    L10n.tr("新しいタスク"),
                    text: Binding(get: { store.editor?.task.title ?? "" }, set: { store.send(.editorTitle($0)) }),
                )
                .textFieldStyle(.plain).font(.system(size: rowFontSize))
                .focused($focusedEditor, equals: editor.id)
                .submitLabel(.next)
                .onSubmit { store.send(.commitEditor(continueAdding: true)) }
                .accessibilityIdentifier("task-title-input")
                TextField(
                    L10n.tr("メモ"),
                    text: Binding(get: { store.editor?.task.notes ?? "" }, set: { store.send(.editorNotes($0)) }),
                )
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                .focused($focusedEditor, equals: editor.id + ".notes")
                .onSubmit { store.send(.commitEditor(continueAdding: false)) }
                HStack(spacing: 12) {
                    if editor.task.due != nil {
                        DatePicker(
                            L10n.tr("予定日"),
                            selection: Binding(
                                get: { store.editor?.task.due?.date ?? .now },
                                set: { store.send(.editorSchedule(editor.task.id, .date(TaskDay(date: $0)))) },
                            ),
                            displayedComponents: .date,
                        )
                        .labelsHidden().datePickerStyle(.compact).font(.caption)
                        Button { store.send(.editorSchedule(editor.task.id, .date(nil))) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L10n.tr("予定日を削除"))
                    } else {
                        Button { store.send(.editorSchedule(editor.task.id, .date(store.today))) } label: {
                            Label(L10n.tr("日付を追加"), systemImage: "calendar")
                        }.buttonStyle(.borderless).font(.caption)
                    }
                    Spacer(minLength: 0)
                    Button(L10n.tr("完了")) { store.send(.commitEditor(continueAdding: false)) }.font(.caption)
                        .buttonStyle(.borderless)
                    if !editor.isNew {
                        Button { store.send(.openDetails(editor.task.id)) } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).accessibilityLabel(L10n.tr(
                                "%@の詳細",
                                String(describing: editor.task.title),
                            ))
                    }
                }
                if !editor.isNew, editor.task.due != nil, store.notifications.preferences.enabled,
                   let date = store.editorNotificationDate
                {
                    DatePicker(L10n.tr("端末の通知"), selection: Binding(
                        get: { store.editorNotificationDate ?? date },
                        set: { store.send(.editorSchedule(editor.task.id, .time($0))) },
                    ), displayedComponents: [.date, .hourAndMinute])
                        .font(.caption)
                    Text(L10n.tr("通知時刻はGoogle Tasksと同期されません。"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, editor.task.parentID == nil ? 0 : 30)
        .padding(.vertical, 13)
        .id(editor.id)
        .task(id: editor.id) {
            // A Return commit replaces the row. Request focus after its field is mounted,
            // otherwise AppKit sends the request to the field that is being removed.
            await Task.yield()
            guard !store.showsVoice, !Task.isCancelled else { return }
            focusedEditor = editor.id
        }
        .overlay(alignment: .bottom) { Divider().padding(.leading, 35).opacity(0.6) }
    }

    private func completionButton(_ task: ReminderTask) -> some View {
        Button { store.send(.toggleComplete(task.id)) } label: {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .ultraLight))
                .foregroundStyle(task.isCompleted ? accent : .secondary)
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L10n.tr(
            "%@を%@にする",
            String(describing: task.title),
            String(describing: task.isCompleted ? L10n.tr("未完了") : L10n.tr("完了")),
        ))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(text).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            if store.writeFailed { Button(L10n.tr("再試行")) { store.send(.retryWrites) }.font(.caption) }
            Button { store.send(.dismissError) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("メッセージを閉じる"))
        }.padding(12).background(.orange.opacity(0.08)).padding(.horizontal, horizontalPadding)
    }
}
