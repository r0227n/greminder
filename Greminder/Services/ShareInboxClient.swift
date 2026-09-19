import ComposableArchitecture
import Foundation
import GreminderShare

struct ShareInboxClient: Sendable {
    var publish: @Sendable (ShareContext?) throws -> Void = { _ in }
    var requests: @Sendable (String) throws -> [ShareRequest] = { _ in [] }
    var stage: @Sendable (ReminderTask) throws -> Void = { _ in }
    var receipt: @Sendable (ReminderTask) throws -> Void = { _ in }
    var requestDeletion: @Sendable (Set<String>, Set<String>) throws -> Void = { _, _ in }
    var confirmDeletion: @Sendable (String, String) throws -> Void = { _, _ in }
    var remove: @Sendable (Set<String>) throws -> Void = { _ in }
}

extension ShareInboxClient: DependencyKey {
    static let liveValue = Self(
        publish: { try ShareInbox.shared().publish($0) },
        requests: { try ShareInbox.shared().requests(scope: $0) },
        stage: { task in
            guard task.id.hasPrefix("share-") else { return }
            try ShareInbox.shared().markSending(
                taskID: task.id,
                title: task.title,
                notes: task.notes,
                due: task.due?.date,
            )
        },
        receipt: { task in
            guard task.id.hasPrefix("share-"), let remoteID = task.remoteID else { return }
            try ShareInbox.shared().markSaved(taskID: task.id, remoteID: remoteID)
        },
        requestDeletion: { ids, inFlightIDs in
            let shared = ids.filter { $0.hasPrefix("share-") }
            guard !shared.isEmpty else { return }
            try ShareInbox.shared().requestDeletion(taskIDs: shared, inFlightTaskIDs: inFlightIDs)
        },
        confirmDeletion: { try ShareInbox.shared().confirmDeletion(taskID: $0, scope: $1) },
        remove: { ids in
            let shared = ids.filter { $0.hasPrefix("share-") }
            guard !shared.isEmpty else { return }
            try ShareInbox.shared().remove(taskIDs: shared)
        },
    )
    static let testValue = Self()
}

extension DependencyValues {
    var shareInbox: ShareInboxClient {
        get { self[ShareInboxClient.self] }
        set { self[ShareInboxClient.self] = newValue }
    }
}
