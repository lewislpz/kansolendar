import Foundation

public struct CalendarMonth: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) throws {
        _ = try CivilDate(year: year, month: month, day: 1)
        self.year = year
        self.month = month
    }

    public init(containing date: CivilDate) {
        year = date.year
        month = date.month
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    public var firstDay: CivilDate {
        // Construction already validated this year/month pair.
        try! CivilDate(year: year, month: month, day: 1)
    }

    public func adding(months delta: Int) throws -> Self {
        let base = (year - 1).multipliedReportingOverflow(by: 12)
        guard !base.overflow else { throw DomainValidationError.arithmeticOverflow }
        let indexedMonth = base.partialValue.addingReportingOverflow(month - 1)
        guard !indexedMonth.overflow else { throw DomainValidationError.arithmeticOverflow }
        let target = indexedMonth.partialValue.addingReportingOverflow(delta)
        guard !target.overflow, (0..<(9_999 * 12)).contains(target.partialValue) else {
            throw DomainValidationError.invalidCivilDate
        }
        return try Self(year: target.partialValue / 12 + 1, month: target.partialValue % 12 + 1)
    }
}

public struct MonthGridDay: Hashable, Sendable, Identifiable {
    public let date: CivilDate
    public let isInDisplayedMonth: Bool

    public var id: CivilDate { date }
}

public struct MonthGrid: Hashable, Sendable {
    public static let dayCount = 42

    public let month: CalendarMonth
    public let days: [MonthGridDay]

    public init(month: CalendarMonth) throws {
        self.month = month
        let leadingDays = month.firstDay.isoWeekday - 1
        let gridStart = try month.firstDay.adding(days: -leadingDays)
        days = try (0..<Self.dayCount).map { offset in
            let date = try gridStart.adding(days: offset)
            return MonthGridDay(
                date: date,
                isInDisplayedMonth: date.year == month.year && date.month == month.month
            )
        }
    }

    public var range: CivilDateRange {
        // A 42-day grid always has a representable final day for supported UI dates.
        try! CivilDateRange(start: days[0].date, endExclusive: days[Self.dayCount - 1].date.adding(days: 1))
    }
}
