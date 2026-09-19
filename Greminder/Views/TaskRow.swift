import SwiftUI

/// A task row renders explicit inputs; the parent owns editing, persistence, and navigation.
struct TaskRow: View {
    @Environment(\.locale) private var locale

    enum Action {
        case edit, showDetails, toggleComplete, toggleChildren, addAfter, addChild, requestDelete, swipeDelete
    }

    let task: ReminderTask
    let listTitle: String
    let today: TaskDay
    let showsDueDate: Bool
    let isSelected: Bool
    let hasChildren: Bool
    let isCollapsed: Bool
    let canSwipeDelete: Bool
    let accent: Color
    let onAction: (Action) -> Void

    private var rowFont: Font {
        #if os(macOS)
            .callout
        #else
            .body
        #endif
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TaskCompletionButton(title: task.title, isCompleted: task.isCompleted, accent: accent) {
                onAction(.toggleComplete)
            }
            Button { onAction(.edit) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title).font(rowFont).strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !task.notes.isEmpty {
                        Text(task.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if task.parentID == nil { Text(listTitle) }
                        if let due = task.due, showsDueDate {
                            Text(due.label)
                                .foregroundStyle(due < today && !task.isCompleted ? Color.red : Color.secondary)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: TaskControlMetrics.minimumSize, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("task-edit-\(task.id)")
            Button { onAction(.showDetails) } label: {
                Image(systemName: "info.circle").font(.body)
                    .frame(width: TaskControlMetrics.minimumSize, height: TaskControlMetrics.minimumSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(accent)
            .help(L10n.tr("詳細を表示")).accessibilityLabel(L10n.tr("%@の詳細", task.title))
            .accessibilityIdentifier("task-details-\(task.id)")
            if hasChildren {
                Button { onAction(.toggleChildren) } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: TaskControlMetrics.minimumSize, height: TaskControlMetrics.minimumSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("サブタスクの表示を切り替える"))
            }
        }
        .padding(.leading, task.parentID == nil ? 0 : 30)
        .padding(.vertical, 14)
        .background(isSelected ? AppTheme.subtle : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, task.parentID == nil ? 35 : 65).opacity(0.6)
        }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { onAction(.swipeDelete) } label: {
                Label(L10n.tr("削除"), systemImage: "trash")
            }
            .tint(.red)
            .accessibilityIdentifier("task-swipe-delete-\(task.id)")
            .disabled(!canSwipeDelete)
        }
        #endif
        .contextMenu {
            Button(L10n.tr("編集")) { onAction(.edit) }
            Button(L10n.tr("詳細"), systemImage: "info.circle") { onAction(.showDetails) }
            Button(L10n.tr("下にタスクを追加")) { onAction(.addAfter) }
            if task.parentID == nil {
                Button(L10n.tr("サブタスクを追加")) { onAction(.addChild) }
            }
            Button(L10n.tr("削除"), role: .destructive) { onAction(.requestDelete) }
        }
    }
}

struct TaskCompletionButton: View {
    @Environment(\.locale) private var locale

    let title: String
    let isCompleted: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .ultraLight))
                .foregroundStyle(isCompleted ? accent : .secondary)
                .frame(width: TaskControlMetrics.minimumSize, height: TaskControlMetrics.minimumSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("%@を%@にする", title, isCompleted ? L10n.tr("未完了") : L10n.tr("完了")))
    }
}

private enum TaskControlMetrics {
    static var minimumSize: CGFloat {
        #if os(iOS)
            44
        #else
            26
        #endif
    }
}
