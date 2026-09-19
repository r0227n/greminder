import Foundation
import GreminderShare

/// App and share extension use the same validated calendar-day representation.
typealias TaskDay = CalendarDay

extension CalendarDay {
    var label: String { date.formatted(.dateTime.month(.defaultDigits).day().locale(L10n.locale)) }
    var apiValue: String { value + "T00:00:00.000Z" }
}

struct TaskList: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var symbol: String = "list.bullet"
    var tint: String = "blue"
}

struct ReminderTask: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var remoteID: String?
    var listID: String
    var title: String
    var notes: String = ""
    var due: TaskDay?
    var isCompleted = false
    var parentID: String?
    var position: String = ""
    var etag: String?
}

struct TaskSnapshot: Codable, Equatable, Sendable {
    var lists: [TaskList] = []
    var tasks: [ReminderTask] = []

    /// The sidebar badge and task list use the same membership rule, including undated children.
    func tasks(for selection: TaskSelection, today: TaskDay) -> [ReminderTask] {
        // Completed is an exact status filter, not a container for unfinished descendants.
        if selection == .completed { return tasks.filter(\.isCompleted) }
        let includedParents = Set(tasks.filter { selection.includes($0, today: today) }.map(\.id))
        return tasks.filter {
            selection.includes($0, today: today)
                || (!$0.isCompleted && $0.parentID.map(includedParents.contains) == true)
        }
    }

    func descendantIDs(of id: String) -> Set<String> {
        var ids: Set<String> = [id]
        while true {
            let children = Set(tasks.filter { $0.parentID.map(ids.contains) == true }.map(\.id))
            let previous = ids.count
            ids.formUnion(children)
            if ids.count == previous { return ids }
        }
    }

    static func sample(today: TaskDay = .today) -> Self {
        let tomorrow = TaskDay(date: Calendar.current.date(byAdding: .day, value: 1, to: today.date)!)
        let lists = [TaskList(id: "work", title: L10n.tr("仕事"), symbol: "briefcase.fill"),
                     TaskList(id: "personal", title: L10n.tr("プライベート"), symbol: "person.fill", tint: "red"),
                     TaskList(id: "shopping", title: L10n.tr("買い物"), symbol: "cart.fill", tint: "green")]
        let values: [(String, String, TaskDay?, Bool)] = [
            (L10n.tr("資料の構成をまとめる"), "work", today, false),
            (L10n.tr("デザイン案を確認する"), "work", today, false),
            (L10n.tr("本を返す"), "personal", today, false),
            (L10n.tr("コーヒー豆を買う"), "shopping", today, false),
            (L10n.tr("来週の打ち合わせを準備する"), "work", tomorrow, false),
            (L10n.tr("議事録を整理する"), "work", tomorrow, false),
            (L10n.tr("読みたい本を探す"), "personal", nil, false),
            (L10n.tr("受信トレイを整理する"), "work", nil, true),
            (L10n.tr("水を飲む"), "personal", nil, true),
            (L10n.tr("ノートを買う"), "shopping", nil, true),
        ]
        return Self(lists: lists, tasks: values.enumerated().map { index, value in
            ReminderTask(
                id: "sample-\(index)",
                remoteID: "sample-\(index)",
                listID: value.1,
                title: value.0,
                due: value.2,
                isCompleted: value.3,
                position: String(format: "%020d", index),
            )
        })
    }
}

enum TaskSelection: Hashable, Sendable {
    case today, scheduled, all, completed, list(String)
    var title: String {
        switch self {
        case .today: L10n.tr("今日")
        case .scheduled: L10n.tr("予定あり")
        case .all: L10n.tr("すべて")
        case .completed: L10n.tr("完了")
        case .list: L10n.tr("リスト")
        }
    }

    var symbol: String {
        switch self {
        case .today: "calendar"
        case .scheduled: "calendar.badge.clock"
        case .all: "tray.fill"
        case .completed: "checkmark"
        case .list: "list.bullet"
        }
    }

    func includes(_ task: ReminderTask, today: TaskDay) -> Bool {
        switch self {
        case .today: !task.isCompleted && task.due.map { $0 <= today } == true
        case .scheduled: !task.isCompleted && task.due != nil
        case .all: !task.isCompleted
        case .completed: task.isCompleted
        case let .list(id): task.listID == id && !task.isCompleted
        }
    }
}

struct TaskEditor: Equatable, Identifiable, Sendable {
    var id: String
    var task: ReminderTask
    var isNew: Bool
    var afterID: String?
    var notificationEdit: TaskNotificationEdit?
}

enum TaskScheduleChange: Equatable, Sendable {
    case date(TaskDay?), time(Date), enabled(Bool)
}

struct TaskNotificationEdit: Equatable, Sendable {
    var date: Date?
    var enabled: Bool?
}

enum TaskInputPolicy {
    static let titleLimit = ShareInputPolicy.titleLimit
    static let notesLimit = ShareInputPolicy.notesLimit
    static let promptLimit = 1500
    static func error(for task: ReminderTask) -> String? {
        if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.tr("タイトルを入力してください。")
        }
        if task.title.trimmingCharacters(in: .whitespacesAndNewlines).count > titleLimit || task.notes
            .count > notesLimit
        {
            return L10n.tr("タイトルは1,024文字、メモは8,192文字以内にしてください。")
        }
        return nil
    }
}

struct PendingWrite: Equatable, Identifiable, Sendable {
    var id = UUID()
    var task: ReminderTask
    var previousID: String?
    var isDelete = false
}

struct AppFailure: Error, Equatable, LocalizedError, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
    init(_ error: Error) { message = error.localizedDescription }
    var errorDescription: String? { message }
}
