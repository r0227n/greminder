import ComposableArchitecture
import SwiftUI

struct NotificationConflictView: View {
    @Environment(\.locale) private var locale
    let store: StoreOf<NotificationFeature>
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.tr("期限を過ぎた端末の通知と、タスクの予定日が異なります。端末の通知日をタスクに合わせますか？"))
                Text(L10n.tr("Google Tasksの通知時刻はAPIで取得できないため、日付だけを比較しています。端末の時刻は維持します。"))
                    .font(.caption).foregroundStyle(.secondary)
                List(store.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conflict.title).font(.headline)
                        Text(L10n.tr(
                            "端末: %@",
                            String(describing: conflict.localDate
                                .formatted(.dateTime.year().month().day().hour().minute().locale(locale))),
                        ))
                        Text(L10n.tr("タスクの予定日: %@", String(describing: conflict.googleDay.label)))
                    }.font(.callout).padding(.vertical, 6)
                }.listStyle(.plain)
                HStack {
                    Button(L10n.tr("No・変更しない")) { store.send(.resolveConflicts(false)) }
                    Spacer()
                    Button(L10n.tr("Yes・端末の日付を更新")) { store.send(.resolveConflicts(true)) }
                        .buttonStyle(.borderedProminent)
                }
            }.padding(22)
                .navigationTitle(L10n.tr("通知日の差分を確認"))
        }
        .interactiveDismissDisabled()
        #if os(macOS)
            .frame(width: 580, height: 550)
        #endif
    }
}
