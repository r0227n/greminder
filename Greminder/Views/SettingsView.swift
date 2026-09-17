import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("表示")) {
                    Picker(L10n.tr("表示言語"), selection: Binding(
                        get: { store.displayLanguage },
                        set: { store.send(.displayLanguageChanged($0)) },
                    )) {
                        ForEach(DisplayLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.accessibilityIdentifier("display-language")
                    Text(L10n.tr("音声認識の言語は「音声入力」で別に設定できます。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("端末内AI")) {
                    Label(
                        store.aiUnavailable == nil ? L10n.tr("このデバイスで利用できます") : L10n.tr("現在は利用できません"),
                        systemImage: "sparkles",
                    )
                    if let reason = store.aiUnavailable { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    Text(L10n.tr("指示の解釈は端末内で行います。Google接続中は、確定したタスクの内容をGoogle Tasksに送信します。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("通知")) {
                    Toggle(L10n.tr("この端末で通知する"), isOn: Binding(
                        get: { store.notifications.preferences.enabled },
                        set: { store.send(.notifications(.setEnabled($0))) },
                    )).disabled(!store.notifications.isLoaded || store.notifications.isRequesting)
                    Text(store.notifications.report.access.label).font(.caption).foregroundStyle(.secondary)
                    if store.notifications.preferences.enabled {
                        DatePicker(L10n.tr("新しいタスクの通知時刻"), selection: Binding(
                            get: { NotificationPlanner.date(
                                day: store.today,
                                hour: store.notifications.preferences.hour,
                                minute: store.notifications.preferences.minute,
                            ) },
                            set: { store.send(.notifications(.defaultTimeChanged($0))) },
                        ), displayedComponents: .hourAndMinute)
                        Text(L10n.tr("予約済み: %@件", String(describing: store.notifications.report.scheduled)))
                        if store.notifications.report.deferred > 0 {
                            Text(L10n.tr("直近60件を予約しています。残りは次回起動・更新時に予約します。"))
                        }
                        Text(L10n.tr("各タスクの編集欄で、この端末の通知日時を変更できます。期限を過ぎた通知日がタスクの予定日と異なる場合、起動時に更新するか確認します。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L10n
                        .tr("Google Tasksの通知時刻はAPIで取得・変更できません。比較・反映できるのは予定日だけです。端末で時刻を変えてもGoogle Tasks側の通知時刻は変わりません。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = store.notifications.error { Text(error).foregroundStyle(.red).font(.caption) }
                }
                Section(L10n.tr("音声入力")) {
                    Picker(L10n.tr("認識言語"), selection: Binding(
                        get: { store.speechSettings.preferences.language },
                        set: { store.send(.speechSettings(.languageChanged($0))) },
                    )) {
                        ForEach(SpeechLanguage.allCases) { Text($0.label).tag($0) }
                    }.accessibilityIdentifier("speech-language")
                    Picker(L10n.tr("音声モデル"), selection: Binding(
                        get: { store.speechSettings.preferences.model },
                        set: { store.send(.speechSettings(.modelChanged($0))) },
                    )) {
                        ForEach(SpeechModel.allCases) { Text($0.label).tag($0) }
                    }.accessibilityIdentifier("speech-model")
                    Text(store.speechSettings.preferences.model.detail)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.tr("変更は次の音声入力から反映します。モデルごとに初回のダウンロードが必要です。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.tr("WhisperKitで端末内で文字起こしします。音声は外部へ送らず、処理後に削除します。ダウンロード済みのモデルは再利用します。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = store.speechSettings.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section(L10n.tr("タスクの入力")) {
                    #if os(macOS)
                        Text(L10n.tr("余白をダブルクリック、または ⌘N で新規入力。Enterで保存して次の行へ。空欄のEnter、またはEscで入力を終了します。"))
                    #else
                        Text(L10n.tr("余白をタップ、または＋で新規入力。「次へ」で保存して次の行へ。空欄の「次へ」で入力を終了します。"))
                    #endif
                    Text(L10n.tr("タイトルを選ぶと、その場でメモと予定日も編集できます。"))
                }.font(.callout)
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.tr("設定"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("完了")) { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 540, height: 570)
        #endif
    }
}
