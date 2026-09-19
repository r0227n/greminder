import Foundation
import GreminderShare
import Testing

@Suite("共有ドラフトのカレンダー日の永続化")
struct SharedCalendarDayTests {
    @Test("日時に変換しても元のカレンダー日を各タイムゾーンで復元する", arguments: [-39600, 0, 32400, 50400])
    func preservesDayAcrossTimeZones(offset: Int) throws {
        let day = try #require(CalendarDay("2026-09-20"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: offset))
        #expect(CalendarDay(date: day.date(in: calendar), calendar: calendar) == day)
    }

    @Test("保存した共有ドラフトは古い絶対日時よりカレンダー日を優先する")
    func canonicalDaySurvivesDifferentLegacyTimestamp() throws {
        var draft = ShareDraft(title: "Travel")
        draft.dueDay = try #require(CalendarDay("2026-09-20"))
        let data = try JSONEncoder().encode(draft)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Simulate a legacy timestamp interpreted as a different day in the current time zone.
        let otherDay = try #require(CalendarDay("2026-09-19"))
        object["due"] = otherDay.date.timeIntervalSinceReferenceDate
        let restored = try JSONDecoder().decode(ShareDraft.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.dueDay == draft.dueDay)
        #expect(restored.due.map { CalendarDay(date: $0) } == draft.dueDay)
    }

    @Test("既存の絶対日時形式を読め、次の保存でカレンダー日を追加する")
    func migratesLegacyDraft() throws {
        let day = try #require(CalendarDay("2026-10-01"))
        let legacy: [String: Any] = [
            "id": UUID().uuidString, "title": "Legacy", "notes": "", "url": "",
            "due": day.date.timeIntervalSinceReferenceDate,
        ]
        let restored = try JSONDecoder().decode(ShareDraft.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.dueDay == day)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        #expect((saved["dueDay"] as? [String: String])?["value"] == day.value)
        #expect(saved["due"] != nil)
    }

    @Test("DatePickerの更新と日付削除は永続化するカレンダー日へ反映する")
    func dateAdapterUsesCanonicalDay() throws {
        let day = try #require(CalendarDay("2026-10-01"))
        var draft = ShareDraft(title: "Date")
        draft.due = day.date
        #expect(draft.dueDay == day)
        draft.due = nil
        #expect(draft.dueDay == nil)
        #expect(try JSONDecoder().decode(ShareDraft.self, from: JSONEncoder().encode(draft)).due == nil)
    }

    @Test("壊れたカレンダー日を古い日時で黙って置き換えない")
    func rejectsInvalidCanonicalDay() throws {
        let object: [String: Any] = [
            "id": UUID().uuidString, "title": "Invalid", "notes": "", "url": "",
            "due": Date.now.timeIntervalSinceReferenceDate, "dueDay": ["value": "2026-02-30"],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ShareDraft.self, from: data) }
    }
}
