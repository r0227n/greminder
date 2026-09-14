import Foundation
@testable import GreminderKit
import XCTest

final class TaskModelTests: XCTestCase {
    func testPersistedDatesMustPassTheSameValidationAsInput() throws {
        for value in ["", "broken", "2026-02-30", "2026-13-01"] {
            let data = try JSONSerialization.data(withJSONObject: ["value": value])
            XCTAssertThrowsError(try JSONDecoder().decode(TaskDay.self, from: data))
        }
        let original = try XCTUnwrap(TaskDay("2026-09-14"))
        XCTAssertEqual(try JSONDecoder().decode(TaskDay.self, from: JSONEncoder().encode(original)), original)
    }

    func testCanonicalDateUsesGregorianYearWithUsersTimeZone() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-13T18:00:00Z"))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(TaskDay(date: date, calendar: buddhist).value, "2026-09-14")
    }

    func testSmartListMembershipIncludesUndatedChildrenAndIsCycleSafe() throws {
        let today = try XCTUnwrap(TaskDay("2026-09-14"))
        let snapshot = TaskSnapshot(tasks: [
            ReminderTask(id: "parent", listID: "work", title: "Parent", due: today),
            ReminderTask(id: "child", listID: "work", title: "Child", parentID: "parent"),
            ReminderTask(id: "done", listID: "work", title: "Done", isCompleted: true, parentID: "parent"),
        ])
        XCTAssertEqual(snapshot.tasks(for: .today, today: today).map(\.id), ["parent", "child"])
        XCTAssertEqual(snapshot.descendantIDs(of: "parent"), ["parent", "child", "done"])
    }
}
