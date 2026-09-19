import ComposableArchitecture
import SwiftUI

struct TaskListView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: StoreOf<AppFeature>
    @FocusState private var focusedEditor: String?
    #if os(iOS)
        @Environment(\.horizontalSizeClass) var horizontalSizeClass
    #endif

    #if os(iOS)
        @State private var rowsHeight: CGFloat = 0
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
            if let review = store.sharedDeletionReview {
                SharedDeletionReviewBanner(review: review) { confirmation in
                    guard store.sharedDeletionReview == confirmation else { return }
                    store.send(.confirmSharedDeletion(confirmation))
                }
                .padding(.horizontal, horizontalPadding)
            }
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    taskScrollContent(height: geometry.size.height)
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
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel(L10n.tr("その他"))
                }
            }
            .tint(accent)
        #if os(macOS)
            .onExitCommand { store.send(.cancelEditor) }
        #endif
    }

    @ViewBuilder private func taskScrollContent(height: CGFloat) -> some View {
        #if os(iOS)
            List {
                listRows
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: TaskRowsHeightKey.self, value: geometry.size.height)
                        }
                    }
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: horizontalPadding,
                        bottom: 0,
                        trailing: horizontalPadding,
                    ))
                    .listRowSeparator(.hidden)
                    .listRowBackground(AppTheme.surface)
                VStack(alignment: .leading, spacing: 0) {
                    listFooter(minimumHeight: max(90, height - rowsHeight - 88))
                }
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: horizontalPadding,
                    bottom: 88,
                    trailing: horizontalPadding,
                ))
                .listRowSeparator(.hidden)
                .listRowBackground(AppTheme.surface)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .onPreferenceChange(TaskRowsHeightKey.self) { rowsHeight = $0 }
        #else
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    listRows
                    listFooter(minimumHeight: 90)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 88)
                .frame(minHeight: height, alignment: .top)
            }
        #endif
    }

    @ViewBuilder private var listRows: some View {
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
    }

    @ViewBuilder private func listFooter(minimumHeight: CGFloat) -> some View {
        blankArea.frame(minHeight: store.proposals.isEmpty ? minimumHeight : 16)
            .frame(maxHeight: .infinity)
        if !store.proposals.isEmpty {
            ProposalPreview(store: store).padding(.top, 14).padding(.bottom, 16)
                .id("proposal-preview")
        }
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
            TaskRow(
                task: task,
                listTitle: store.snapshot.lists.first { $0.id == task.listID }?.title ?? "",
                today: store.today,
                showsDueDate: store.selection != .today,
                isSelected: store.showsTaskDetails && store.editor?.task.id == task.id,
                hasChildren: store.snapshot.tasks.contains { $0.parentID == task.id },
                isCollapsed: store.collapsed.contains(task.id),
                canSwipeDelete: !store.isLoading && !store.showsVoice,
                accent: accent,
            ) { action in
                switch action {
                case .edit: store.send(.edit(task.id))
                case .showDetails: store.send(.openDetails(task.id))
                case .toggleComplete: store.send(.toggleComplete(task.id))
                case .toggleChildren: store.send(.toggleChildren(task.id))
                case .addAfter: store.send(.beginAdd(after: task.id, parent: task.parentID))
                case .addChild: store.send(.beginAdd(after: task.id, parent: task.id))
                case .requestDelete: store.send(.requestDelete(task.id))
                case .swipeDelete: store.send(.swipeDelete(task.id), animation: .default)
                }
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
                    TaskNotificationEditor(
                        isEnabled: Binding(
                            get: { store.editorNotificationEnabled },
                            set: { store.send(.editorSchedule(editor.task.id, .enabled($0))) },
                        ),
                        date: Binding(
                            get: { store.editorNotificationDate ?? date },
                            set: { store.send(.editorSchedule(editor.task.id, .time($0))) },
                        ),
                        isLoaded: store.notifications.isLoaded,
                    )
                    .font(.caption)
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
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) { Divider() }.padding(.leading, 35).opacity(0.6)
        }
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

private struct SharedDeletionReviewBanner: View {
    @Environment(\.locale) private var locale
    let review: SharedDeletionReview
    let onConfirm: (SharedDeletionReview) -> Void
    @State private var confirmation: SharedDeletionReview?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.tr("「%@」の保存結果を確認してください", review.title), systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
                .lineLimit(3)
            Text(L10n.tr("この共有タスクは削除操作中に保存結果が不明になりました。Google Tasksで確認し、残っていれば削除してください。"))
                .font(.caption)
            Button(L10n.tr("Google Tasksで確認済み…")) { confirmation = review }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("shared-deletion-review-open")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.08))
        .accessibilityIdentifier("shared-deletion-review")
        .onChange(of: review) { _, _ in confirmation = nil }
        .confirmationDialog(
            L10n.tr("「%@」の確認記録を削除しますか？", confirmation?.title ?? review.title),
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } },
            ),
            titleVisibility: .visible,
            presenting: confirmation,
        ) { capturedReview in
            Button(L10n.tr("確認済み・記録を削除"), role: .destructive) {
                guard capturedReview == review else { return }
                onConfirm(capturedReview)
                confirmation = nil
            }
            .accessibilityIdentifier("shared-deletion-review-confirm")
            Button(L10n.tr("キャンセル"), role: .cancel) { confirmation = nil }
        } message: { _ in
            Text(L10n.tr("Google Tasksにこのタスクが残っていないことを確認した場合のみ、この端末の確認記録を削除してください。"))
        }
    }
}

#if os(iOS)
    private struct TaskRowsHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value += nextValue()
        }
    }
#endif
