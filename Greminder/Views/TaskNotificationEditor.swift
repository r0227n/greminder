import SwiftUI

/// Reflects whether a notification is actually enabled instead of implying that a saved time enables it.
struct TaskNotificationEditor: View {
    @Environment(\.locale) private var locale
    @Binding var isEnabled: Bool
    @Binding var date: Date
    let isLoaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.tr("端末の通知"), isOn: $isEnabled)
                .accessibilityIdentifier("task-notification-enabled")
            if isEnabled {
                DatePicker(L10n.tr("端末の通知"), selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier("task-notification-date")
            }
            Text(L10n.tr("通知時刻はこの端末に保存されます。Google Tasksとは予定日のみ同期します。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!isLoaded)
    }
}
