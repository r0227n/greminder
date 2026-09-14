/// A proposal only. The app validates IDs and values against its current data before applying it.
public struct TaskPlan: Codable, Equatable, Sendable {
    public var operations: [TaskPlanOperation]

    public init(operations: [TaskPlanOperation]) {
        self.operations = operations
    }
}

public struct TaskPlanOperation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case add, reschedule, complete }
    public var kind: Kind
    public var taskID: String
    public var title: String
    public var listID: String
    public var date: String
    public var subtasks: [String]

    public init(
        kind: Kind,
        taskID: String = "",
        title: String = "",
        listID: String,
        date: String = "",
        subtasks: [String] = [],
    ) {
        self.kind = kind
        self.taskID = taskID
        self.title = title
        self.listID = listID
        self.date = date
        self.subtasks = subtasks
    }
}
