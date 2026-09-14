import ComposableArchitecture
import CryptoKit
import Foundation
import UserNotifications

struct NotificationRecord: Codable, Equatable, Sendable {
    var date: Date
    var sourceDay: TaskDay
    var isEnabled = true

    init(date: Date, sourceDay: TaskDay, isEnabled: Bool = true) {
        self.date = date
        self.sourceDay = sourceDay
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case date, sourceDay, isEnabled }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(Date.self, forKey: .date)
        sourceDay = try values.decode(TaskDay.self, forKey: .sourceDay)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

struct NotificationPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var hour = 9
    var minute = 0
    var records: [String: NotificationRecord] = [:]
}

extension NotificationPreferences {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        hour = try values.decode(Int.self, forKey: .hour)
        minute = try values.decode(Int.self, forKey: .minute)
        records = try values.decode([String: NotificationRecord].self, forKey: .records)
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Notification clock time must be within 00:00...23:59.",
            ))
        }
    }
}

struct NotificationConflict: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var localDate: Date
    var googleDay: TaskDay
}

struct ScheduledTaskNotification: Equatable, Sendable {
    var id: String
    var title: String
    var listTitle: String
    var date: Date
}

enum NotificationAccess: String, Equatable, Sendable {
    case notDetermined, denied, authorized, unavailable
    var label: String {
        switch self {
        case .notDetermined: L10n.tr("通知は未許可です")
        case .denied: L10n.tr("システム設定で通知を許可してください")
        case .authorized: L10n.tr("通知を利用できます")
        case .unavailable: L10n.tr("通知を利用できません")
        }
    }
}

struct NotificationReport: Equatable, Sendable {
    var access: NotificationAccess
    var scheduled = 0
    var deferred = 0
}

/// Google exposes a calendar day, not a reminder time. Keep that boundary explicit.
enum NotificationPlanner {
    static func scope(_ account: String?) -> String {
        digest(account.map { "google:\($0)" } ?? "sample")
    }

    static func key(task: ReminderTask, scope: String) -> String {
        scope + "." + digest(task.listID + ":" + (task.remoteID ?? task.id))
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func date(day: TaskDay, hour: Int, minute: Int, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = day.value.split(separator: "-").compactMap { Int($0) }
        let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
        // nextTime moves a nonexistent DST clock time forward instead of losing the reminder.
        return calendar.nextDate(
            after: start.addingTimeInterval(-1),
            matching: DateComponents(hour: hour, minute: minute),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
        )!
    }

    static func replacingDay(of date: Date, with day: TaskDay, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return self.date(day: day, hour: time.hour ?? 9, minute: time.minute ?? 0, timeZone: timeZone)
    }

    static func update(
        preferences: inout NotificationPreferences,
        snapshot: TaskSnapshot,
        scope: String,
        now: Date,
        reviewOverdue: Bool,
        ignored: Set<String> = [],
    ) -> [NotificationConflict] {
        let active = snapshot.tasks.filter { !$0.isCompleted && $0.due != nil }
        // A successful insert attaches a remote ID while retaining the local UI ID.
        // Transfer custom clock times and per-task switches before pruning stale keys.
        for task in active where task.remoteID != nil && task.remoteID != task.id {
            var localTask = task
            localTask.remoteID = nil
            let localKey = key(task: localTask, scope: scope)
            let remoteKey = key(task: task, scope: scope)
            if let record = preferences.records.removeValue(forKey: localKey), preferences.records[remoteKey] == nil {
                preferences.records[remoteKey] = record
            }
        }
        let keys = Set(active.map { key(task: $0, scope: scope) })
        preferences.records = preferences.records.filter { !$0.key.hasPrefix(scope + ".") || keys.contains($0.key) }
        var conflicts: [NotificationConflict] = []
        let calendar = Calendar(identifier: .gregorian)
        for task in active {
            guard let due = task.due else { continue }
            let key = key(task: task, scope: scope)
            if var record = preferences.records[key] {
                let localDay = TaskDay(date: record.date, calendar: calendar)
                if record.isEnabled, localDay != due, record.date < now {
                    if reviewOverdue, !ignored.contains(key + due.value) {
                        conflicts.append(NotificationConflict(
                            id: key,
                            title: task.title,
                            localDate: record.date,
                            googleDay: due,
                        ))
                    }
                    // Never silently replace an overdue conflicting local notification.
                } else if record.sourceDay != due {
                    record.date = replacingDay(of: record.date, with: due)
                    record.sourceDay = due
                    preferences.records[key] = record
                }
            } else {
                preferences.records[key] = NotificationRecord(
                    date: date(day: due, hour: preferences.hour, minute: preferences.minute),
                    sourceDay: due,
                )
            }
        }
        return conflicts.sorted { $0.localDate < $1.localDate }
    }

    static func requests(
        preferences: NotificationPreferences,
        snapshot: TaskSnapshot,
        scope: String,
        now: Date,
    ) -> [ScheduledTaskNotification] {
        guard preferences.enabled else { return [] }
        return snapshot.tasks.compactMap { task in
            let key = key(task: task, scope: scope)
            guard !task.isCompleted, task.due != nil, let record = preferences.records[key],
                  record.isEnabled, record.date > now else { return nil }
            return ScheduledTaskNotification(
                id: "greminder.task." + key,
                title: task.title,
                listTitle: snapshot.lists.first { $0.id == task.listID }?.title ?? L10n.tr("タスク"),
                date: record.date,
            )
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}

struct NotificationClient: Sendable {
    var load: @Sendable () async throws -> NotificationPreferences
    var saveAndSchedule: @Sendable (NotificationPreferences, [ScheduledTaskNotification]) async throws
        -> NotificationReport
    var requestAccess: @Sendable () async throws -> NotificationAccess
}

extension NotificationClient: DependencyKey {
    static let liveValue = Self(
        load: { try await LocalNotificationSystem.shared.load() },
        saveAndSchedule: { try await LocalNotificationSystem.shared.enqueue($0, requests: $1) },
        requestAccess: { try await LocalNotificationSystem.shared.requestAccess() },
    )
    static let testValue = Self(
        load: { NotificationPreferences() },
        saveAndSchedule: { _, requests in NotificationReport(access: .notDetermined, scheduled: requests.count) },
        requestAccess: { .denied },
    )
}

extension DependencyValues {
    var notifications: NotificationClient {
        get { self[NotificationClient.self] }
        set { self[NotificationClient.self] = newValue }
    }
}

@MainActor
final class LocalNotificationSystem: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotificationSystem()
    private var tail: Task<NotificationReport, Error>?
    private let preferencesKey = "greminder.notifications.v1"
    private var center: UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }

    func load() throws -> NotificationPreferences {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey) else { return NotificationPreferences() }
        return try JSONDecoder().decode(NotificationPreferences.self, from: data)
    }

    func requestAccess() async throws -> NotificationAccess {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await access()
    }

    // A serial task chain prevents an older asynchronous OS update from winning a race.
    func enqueue(
        _ preferences: NotificationPreferences,
        requests: [ScheduledTaskNotification],
    ) async throws -> NotificationReport {
        let previous = tail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try UserDefaults.standard.set(JSONEncoder().encode(preferences), forKey: preferencesKey)
            let access = await self.access()
            let pending = await self.center.pendingNotificationRequests()
            let desired = access == .authorized ? Array(requests.prefix(60)) : []
            let desiredIDs = Set(desired.map(\.id))
            self.center
                .removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier)
                    .filter { $0.hasPrefix("greminder.task.") && !desiredIDs.contains($0) })
            for request in desired {
                let content = UNMutableNotificationContent()
                content.title = request.title
                content.body = request.listTitle
                content.sound = .default
                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: request.date,
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                try await self.center.add(UNNotificationRequest(
                    identifier: request.id,
                    content: content,
                    trigger: trigger,
                ))
            }
            return NotificationReport(access: access, scheduled: desired.count, deferred: max(0, requests.count - 60))
        }
        tail = task
        return try await task.value
    }

    private func access() async -> NotificationAccess {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
