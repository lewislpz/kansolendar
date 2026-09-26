import Testing
@testable import KansolendarCore

@Suite("Calendar month grid")
struct CalendarMonthTests {
    @Test("renders six complete Monday-first weeks across month boundaries")
    func completeGrid() throws {
        let grid = try MonthGrid(month: CalendarMonth(year: 2026, month: 9))
        let expectedStart = try CivilDate(year: 2026, month: 8, day: 31)
        let expectedEnd = try CivilDate(year: 2026, month: 10, day: 11)

        #expect(grid.days.count == 42)
        #expect(grid.days.first?.date == expectedStart)
        #expect(grid.days.last?.date == expectedEnd)
        #expect(grid.days.first?.date.isoWeekday == 1)
        #expect(grid.days.filter(\.isInDisplayedMonth).count == 30)
        #expect(grid.range.dayCount == 42)
    }

    @Test("month navigation crosses years and preserves valid bounds")
    func navigation() throws {
        let january = try CalendarMonth(year: 2026, month: 1)
        #expect(try january.adding(months: -1) == CalendarMonth(year: 2025, month: 12))
        #expect(try january.adding(months: 12) == CalendarMonth(year: 2027, month: 1))
        #expect(throws: DomainValidationError.invalidCivilDate) {
            try CalendarMonth(year: 1, month: 1).adding(months: -1)
        }
    }

    @Test("leap February includes the 29th exactly once")
    func leapFebruary() throws {
        let grid = try MonthGrid(month: CalendarMonth(year: 2024, month: 2))
        let leapDay = try CivilDate(year: 2024, month: 2, day: 29)
        #expect(grid.days.filter { $0.isInDisplayedMonth }.count == 29)
        #expect(grid.days.filter { $0.date == leapDay }.count == 1)
    }
}
