import Foundation

/// A Gregorian calendar day shared by the app and its extension, without an absolute time.
public struct CalendarDay: Codable, Hashable, Comparable, Sendable {
    public let value: String

    public init?(_ value: String) {
        guard value.count == 10 else { return nil }
        let parser = Self.formatter
        guard let date = parser.date(from: value), parser.string(from: date) == value else { return nil }
        self.value = value
    }

    public init(date: Date, calendar: Calendar = .current) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        value = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private enum CodingKeys: String, CodingKey { case value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        guard let valid = Self(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "Invalid ISO calendar day",
            )
        }
        self = valid
    }

    public static var today: Self { Self(date: .now) }
    public var date: Date { date(in: .current) }

    public func date(in calendar: Calendar) -> Date {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
            ?? Self.formatter.date(from: value)!
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
