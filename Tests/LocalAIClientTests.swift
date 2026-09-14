@testable import GreminderKit
import LocalLLM
import XCTest

final class LocalAIClientTests: XCTestCase {
    func testPackagePlanBecomesValidatedAppProposal() throws {
        let snapshot = TaskSnapshot(lists: [TaskList(id: "list", title: "List")])
        let plan = TaskPlan(operations: [TaskPlanOperation(
            kind: .add, title: "  Draft  ", listID: "list", date: "2026-09-20", subtasks: ["Outline"],
        )])
        let proposals = try LocalAIClient.validate(plan, snapshot: snapshot)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].task.title, "Draft")
        XCTAssertEqual(proposals[0].task.due, TaskDay("2026-09-20"))
        XCTAssertEqual(proposals[0].subtasks, ["Outline"])
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testPackagePlanCannotTargetUnknownOrDuplicateTask() {
        let snapshot = TaskSnapshot(
            lists: [TaskList(id: "list", title: "List")],
            tasks: [ReminderTask(id: "task", listID: "list", title: "Existing")],
        )
        let missing = TaskPlanOperation(kind: .complete, taskID: "missing", listID: "list")
        XCTAssertThrowsError(try LocalAIClient.validate(TaskPlan(operations: [missing]), snapshot: snapshot))
        let existing = TaskPlanOperation(kind: .complete, taskID: "task", listID: "list")
        XCTAssertThrowsError(try LocalAIClient.validate(TaskPlan(operations: [existing, existing]), snapshot: snapshot))
        let invalidDate = TaskPlanOperation(kind: .reschedule, taskID: "task", listID: "list", date: "tomorrow")
        XCTAssertThrowsError(try LocalAIClient.validate(TaskPlan(operations: [invalidDate]), snapshot: snapshot))
    }
}
