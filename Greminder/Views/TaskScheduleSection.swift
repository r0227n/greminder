#if os(iOS)
    import ComposableArchitecture
    import SwiftUI

    struct TaskScheduleSection: View {
        @Environment(\.locale) private var locale
        @Bindable var store: StoreOf<AppFeature>
        let onInteraction: () -> Void
        @State private var expanded: Field?
        private enum Field { case date, time }

        private var task: ReminderTask? { store.editor?.task }
        private var accent: Color { AppTheme.tint(.list(task?.listID ?? ""), lists: store.snapshot.lists) }
        private var notificationDate: Date { store.editorNotificationDate ?? store.today.date }
        private var hasTime: Bool { store.editorNotificationEnabled }

        private var dateLabel: String? {
            guard let due = task?.due else { return nil }
            if due == store.today { return L10n.tr("今日") }
            return due.date.formatted(.dateTime.year().month().day().locale(locale))
        }

        var body: some View {
            Section {
                scheduleRow(
                    title: L10n.tr("日付"),
                    symbol: "calendar",
                    value: dateLabel,
                    field: .date,
                    isOn: Binding(get: { task?.due != nil }, set: setDateEnabled),
                    identifier: "task-detail-has-date",
                )
                if expanded == .date, task?.due != nil {
                    DatePicker(L10n.tr("予定日"), selection: Binding(
                        get: { task?.due?.date ?? store.today.date }, set: setDate,
                    ), displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden()
                        .accessibilityIdentifier("task-detail-calendar")
                }
                scheduleRow(
                    title: L10n.tr("時刻"),
                    symbol: "clock",
                    value: hasTime ? notificationDate.formatted(.dateTime.hour().minute().locale(locale)) : nil,
                    field: .time,
                    isOn: Binding(get: { hasTime }, set: setTimeEnabled),
                    identifier: "task-detail-has-time",
                )
                .disabled(!store.notifications.isLoaded || !store.notifications.preferences.enabled)
                if expanded == .time, hasTime {
                    DatePicker(L10n.tr("時刻"), selection: Binding(
                        get: { notificationDate }, set: setTime,
                    ), displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden()
                        .accessibilityIdentifier("task-detail-time-wheel")
                }
                if hasTime {
                    LabeledContent {
                        Text(TimeZone.current.localizedName(for: .generic, locale: locale) ?? TimeZone.current
                            .identifier)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(L10n.tr("時間帯"), systemImage: "globe")
                    }
                }
                if !store.notifications.preferences.enabled {
                    Button {
                        onInteraction()
                        store.showsSettings = true
                    } label: {
                        Label { Text(L10n.tr("通知を設定…")).foregroundStyle(.primary) } icon: {
                            Image(systemName: "bell").foregroundStyle(accent)
                        }
                    }.buttonStyle(.plain)
                }
                if let error = store.notifications.error { Text(error).foregroundStyle(.red) }
            } header: {
                Text(L10n.tr("日付と時刻"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("通知時刻はこの端末に保存されます。Google Tasksとは予定日のみ同期します。"))
                    if hasTime, let due = task?.due, TaskDay(date: notificationDate) != due {
                        Text(L10n.tr(
                            "端末: %@",
                            notificationDate.formatted(.dateTime.year().month().day().hour().minute().locale(locale)),
                        ))
                    }
                }
            }
        }

        private func scheduleRow(
            title: String,
            symbol: String,
            value: String?,
            field: Field,
            isOn: Binding<Bool>,
            identifier: String,
        ) -> some View {
            HStack(spacing: 16) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 24)
                Button {
                    onInteraction()
                    if !isOn.wrappedValue { isOn.wrappedValue = true }
                    else { expanded = expanded == field ? nil : field }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).foregroundStyle(.primary)
                        if let value { Text(value).font(.subheadline).foregroundStyle(accent) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier(identifier + "-row")
                Toggle(title, isOn: isOn).labelsHidden().fixedSize()
                    .accessibilityIdentifier(identifier)
            }
            .padding(.vertical, 3)
        }

        private func setDateEnabled(_ enabled: Bool) {
            onInteraction()
            guard let task else { return }
            store.send(.editorSchedule(task.id, .date(enabled ? task.due ?? store.today : nil)))
            expanded = enabled ? .date : nil
        }

        private func setDate(_ date: Date) {
            onInteraction()
            guard let task else { return }
            store.send(.editorSchedule(task.id, .date(TaskDay(date: date))))
        }

        private func setTimeEnabled(_ enabled: Bool) {
            onInteraction()
            guard let task else { return }
            store.send(.editorSchedule(task.id, .enabled(enabled)))
            expanded = enabled ? .time : nil
        }

        private func setTime(_ date: Date) {
            onInteraction()
            guard let task else { return }
            store.send(.editorSchedule(task.id, .time(date)))
        }
    }
#endif
