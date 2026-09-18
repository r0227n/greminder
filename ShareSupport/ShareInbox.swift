import Foundation

/// The extension only commits local data. OAuth and Google Tasks writes remain in the app.
/// NSFileCoordinator serializes read/modify/write across both processes; atomic replacement
/// makes each group of reminders all-or-nothing, even if the extension is terminated.
public struct ShareInbox: Sendable {
    public static let groupIdentifier = "group.com.example.greminder"
    public let directory: URL

    private struct Contents: Codable {
        var version = 1
        var context: ShareContext?
        var requests: [ShareRequest] = []
    }

    public init(directory: URL) { self.directory = directory }

    public static func shared() throws -> Self {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier,
        ) else { throw ShareInboxError.unavailable }
        return Self(directory: directory.appendingPathComponent("ShareInbox", isDirectory: true))
    }

    public func context() throws -> ShareContext? { try access(write: false) { $0.context } }
    public func publish(_ context: ShareContext?) throws {
        try access { contents in
            var context = context
            if context?.selectedListID == nil, let previous = contents.context,
               previous.scope == context?.scope,
               context?.lists.contains(where: { $0.id == previous.selectedListID }) == true
            {
                context?.selectedListID = previous.selectedListID
            }
            contents.context = context
        }
    }

    public func requests(scope: String) throws -> [ShareRequest] {
        try access(write: false) { $0.requests.filter { $0.scope == scope }.sorted { $0.createdAt < $1.createdAt } }
    }

    public func enqueue(_ drafts: [ShareDraft], context: ShareContext, listID: String) throws {
        guard !drafts.isEmpty, drafts.allSatisfy({ $0.validationError == nil }) else {
            throw ShareInboxError.invalidDraft
        }
        try access { contents in
            guard let current = contents.context, current.scope == context.scope,
                  current.lists.contains(where: { $0.id == listID }) else { throw ShareInboxError.destinationChanged }
            var existing = Set(contents.requests.map(\.id))
            for draft in drafts where existing.insert(draft.id).inserted {
                contents.requests.append(ShareRequest(scope: context.scope, listID: listID, draft: draft))
            }
            contents.context?.selectedListID = listID
        }
    }

    public func markSending(taskID: String, title: String, notes: String, due: Date?) throws {
        try access { contents in
            guard let index = contents.requests.firstIndex(where: { $0.draft.taskID == taskID }) else { return }
            contents.requests[index].draft.title = title
            contents.requests[index].draft.notes = notes
            // notes already contains the URL when a task is edited in the containing app.
            contents.requests[index].draft.url = ""
            contents.requests[index].draft.due = due
            contents.requests[index].phase = .sending
        }
    }

    public func markSaved(taskID: String, remoteID: String) throws {
        try access { contents in
            guard let index = contents.requests.firstIndex(where: { $0.draft.taskID == taskID }) else { return }
            contents.requests[index].remoteID = remoteID
            contents.requests[index].phase = .saved
        }
    }

    public func remove(taskIDs: Set<String>) throws {
        try access { $0.requests.removeAll { taskIDs.contains($0.draft.taskID) } }
    }

    private func access<T>(write: Bool = true, _ operation: (inout Contents) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("inbox.json")
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { url in
            result = Result {
                var contents = Contents()
                if FileManager.default.fileExists(atPath: url.path) {
                    contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: url))
                    guard contents.version == 1 else { throw ShareInboxError.unsupportedVersion }
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let original = try encoder.encode(contents)
                let result = try operation(&contents)
                let updated = try encoder.encode(contents)
                if write, original != updated {
                    try updated.write(to: url, options: .atomic)
                }
                return result
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ShareInboxError.unavailable }
        return try result.get()
    }
}

public enum ShareInboxError: Error, LocalizedError {
    case unavailable, invalidDraft, destinationChanged, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .unavailable: "共有データを開けません。greminderを一度開いてください。"
        case .invalidDraft: "タイトル、メモ、URLを確認してください。"
        case .destinationChanged: "保存先が変更されました。共有画面を開き直してください。"
        case .unsupportedVersion: "共有データの形式に対応していません。アプリを更新してください。"
        }
    }
}
