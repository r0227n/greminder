import GreminderShare
import SwiftUI

struct ShareComposerView: View {
    let loadItems: @MainActor () async throws -> [ShareDraft]
    let complete: () -> Void
    let cancel: () -> Void
    @State private var context: ShareContext?
    @State private var drafts: [ShareDraft] = []
    @State private var listID = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?
    @State private var details: UUID?
    private var strings: ShareStrings {
        ShareStrings(language: context?.language ?? Locale.preferredLanguages.first ?? "en")
    }

    private var nonemptyDrafts: [ShareDraft] { drafts.filter { !$0.isEmpty } }
    private var canSave: Bool {
        !isLoading && !isSaving && context?.lists.contains { $0.id == listID } == true
            && !nonemptyDrafts.isEmpty && nonemptyDrafts.allSatisfy { $0.validationError == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if let context {
                        Section {
                            Picker(strings("リスト"), selection: $listID) {
                                ForEach(context.lists) { list in
                                    Label(list.title, systemImage: list.symbol).tag(list.id)
                                }
                            }
                            .accessibilityIdentifier("share.list")
                            Text(context.accountName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        ForEach($drafts) { $draft in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Image(systemName: "circle").foregroundStyle(.secondary).padding(.top, 5)
                                    TextField(strings("タイトル"), text: $draft.title, axis: .vertical)
                                        .accessibilityIdentifier("share.title")
                                    Button {
                                        details = details == draft.id ? nil : draft.id
                                    } label: { Image(systemName: "info.circle") }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(strings("詳細"))
                                }
                                if !draft.url.isEmpty {
                                    Text(draft.url).font(.caption).foregroundStyle(.blue).lineLimit(3)
                                        .textSelection(.enabled)
                                }
                                if let due = draft.due {
                                    Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if details == draft.id {
                                    ShareDraftDetails(
                                        draft: $draft,
                                        strings: strings,
                                        notificationsEnabled: context?.notificationsEnabled == true,
                                    )
                                    if drafts.count > 1 {
                                        Button(strings("削除"), role: .destructive) {
                                            drafts.removeAll { $0.id == draft.id }
                                        }
                                    }
                                }
                                if let validation = draft.validationError, !draft.isEmpty {
                                    Text(strings(validation)).font(.caption).foregroundStyle(.red)
                                }
                            }.padding(.vertical, 4)
                        }
                        Button {
                            let draft = ShareDraft()
                            drafts.append(draft)
                            details = draft.id
                        } label: { Label(strings("新規ToDo"), systemImage: "plus.circle") }
                            .accessibilityIdentifier("share.new")
                    }
                    Section {
                        Text(strings("ToDoはこの端末に保存され、greminderを開くとGoogle Tasksに同期されます。"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let error {
                            Text(strings(error)).foregroundStyle(.red).accessibilityIdentifier("share.error")
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(isSaving)
            }
        }
        .environment(\.locale, Locale(identifier: context?.language ?? Locale.preferredLanguages.first ?? "en"))
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Button(strings("キャンセル"), action: cancel).keyboardShortcut(.cancelAction).disabled(isSaving)
            Spacer()
            Text(strings("Taskを追加")).font(.headline)
            Spacer()
            Button(action: save) {
                if isSaving { ProgressView().controlSize(.small) } else { Text(strings("追加")) }
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(!canSave).accessibilityIdentifier("share.add")
        }.padding()
    }

    @MainActor private func load() async {
        defer { isLoading = false }
        do {
            context = try ShareInbox.shared().context()
            drafts = try await loadItems()
            guard let context, !context.lists.isEmpty else {
                error = "greminderを開いて、Googleに接続してリストを読み込んでください。"
                return
            }
            listID = context.lists.first { $0.id == context.selectedListID }?.id ?? context.lists[0].id
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard canSave, let context else { return }
        isSaving = true
        do {
            try ShareInbox.shared().enqueue(nonemptyDrafts, context: context, listID: listID)
            complete()
        } catch {
            self.error = error.localizedDescription
            isSaving = false
        }
    }
}

private struct ShareDraftDetails: View {
    @Binding var draft: ShareDraft
    let strings: ShareStrings
    let notificationsEnabled: Bool

    var body: some View {
        TextField(strings("メモ"), text: $draft.notes, axis: .vertical).lineLimit(3 ... 8)
        TextField("URL", text: $draft.url, axis: .vertical)
            .accessibilityIdentifier("share.url")
        Toggle(strings("日付"), isOn: Binding(
            get: { draft.due != nil },
            set: { draft.due = $0 ? .now : nil
                if !$0 { draft.notificationDate = nil }
            },
        ))
        if let due = draft.due {
            DatePicker(strings("予定日"), selection: Binding(get: { due }, set: { value in
                draft.due = value
                if let time = draft.notificationDate {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                    draft.notificationDate = Calendar.current.date(
                        bySettingHour: parts.hour ?? 9,
                        minute: parts.minute ?? 0,
                        second: 0,
                        of: value,
                    )
                }
            }), displayedComponents: .date)
            Toggle(strings("通知時刻"), isOn: Binding(
                get: { draft.notificationDate != nil },
                set: { draft.notificationDate = $0 ? Calendar.current.date(
                    bySettingHour: 9,
                    minute: 0,
                    second: 0,
                    of: due,
                ) : nil },
            ))
            .disabled(!notificationsEnabled)
            if let date = draft.notificationDate {
                DatePicker(
                    strings("時刻"),
                    selection: Binding(get: { date }, set: { draft.notificationDate = $0 }),
                    displayedComponents: .hourAndMinute,
                )
            }
            if !notificationsEnabled {
                Text(strings("通知を使うにはgreminderの設定で通知を有効にしてください。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
