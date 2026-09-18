import Foundation

public struct ShareList: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String

    public init(id: String, title: String, symbol: String = "list.bullet") {
        self.id = id
        self.title = title
        self.symbol = symbol
    }
}

public struct ShareContext: Codable, Equatable, Sendable {
    public var scope: String
    public var accountName: String
    public var lists: [ShareList]
    public var selectedListID: String?
    public var language: String
    public var notificationsEnabled: Bool

    public init(
        scope: String,
        accountName: String,
        lists: [ShareList],
        selectedListID: String?,
        language: String,
        notificationsEnabled: Bool,
    ) {
        self.scope = scope
        self.accountName = accountName
        self.lists = lists
        self.selectedListID = selectedListID
        self.language = language
        self.notificationsEnabled = notificationsEnabled
    }
}

public struct ShareDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var url: String
    public var due: Date?
    public var notificationDate: Date?

    public init(
        id: UUID = UUID(),
        title: String = "",
        notes: String = "",
        url: String = "",
        due: Date? = nil,
        notificationDate: Date? = nil,
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.url = url
        self.due = due
        self.notificationDate = notificationDate
    }

    public var taskID: String { "share-" + id.uuidString }
    public var taskNotes: String {
        let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !text.components(separatedBy: .newlines).contains(link) else { return text }
        return [text, link].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && taskNotes.isEmpty
    }

    public var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "タイトルを入力してください。" }
        if title.count > ShareInputPolicy.titleLimit || taskNotes.count > ShareInputPolicy.notesLimit {
            return "タイトルは1,024文字、メモは8,192文字以内にしてください。"
        }
        if !url.isEmpty, Self.webURL(url) == nil { return "有効なhttpまたはhttpsのURLを入力してください。" }
        if notificationDate != nil, due == nil { return "通知には日付を設定してください。" }
        return nil
    }

    public static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    public static func received(title: String?, text: String?, url: URL?) -> Self {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = url?.absoluteString ?? ""
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        let suggested = !title.isEmpty ? title : (!firstLine.isEmpty && firstLine != link ? firstLine : url?.host ?? "")
        let taskTitle = String(suggested.prefix(ShareInputPolicy.titleLimit))
        return Self(
            title: taskTitle,
            notes: text == taskTitle || text == link ? "" : text,
            url: link,
        )
    }
}

public enum ShareInputPolicy {
    public static let titleLimit = 1024
    public static let notesLimit = 8192
}

public struct ShareRequest: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable { case queued, sending, saved }
    public var id: UUID { draft.id }
    public var scope: String
    public var listID: String
    public var draft: ShareDraft
    public var createdAt: Date
    public var phase: Phase = .queued
    public var remoteID: String?

    public init(scope: String, listID: String, draft: ShareDraft, createdAt: Date = .now) {
        self.scope = scope
        self.listID = listID
        self.draft = draft
        self.createdAt = createdAt
    }
}
