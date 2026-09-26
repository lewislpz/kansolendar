import Foundation
import KansolendarCore
import Testing

@Suite("Event domain values")
struct EventDomainTests {
    @Test("moving events preserves duration and clock semantics")
    func movingEvents() throws {
        let target = try CivilDate(year: 2026, month: 10, day: 4)

        let allDay = EventTime.allDay(try AllDayEventTime(
            start: CivilDate(year: 2026, month: 9, day: 1),
            endExclusive: CivilDate(year: 2026, month: 9, day: 4)
        ))
        guard case let .allDay(movedAllDay) = try allDay.moved(to: target) else {
            Issue.record("Expected all-day time")
            return
        }
        #expect(movedAllDay.range.start == target)
        #expect(movedAllDay.durationInDays == 3)

        let utc = EventTime.utc(try TimedEventTime(
            start: Instant(unixSeconds: 9 * 3_600 + 30 * 60),
            durationSeconds: 5_400
        ))
        guard case let .utc(movedUTC) = try utc.moved(to: target) else {
            Issue.record("Expected UTC time")
            return
        }
        #expect(movedUTC.start.unixSeconds == target.daysSinceUnixEpoch * 86_400 + 9 * 3_600 + 30 * 60)
        #expect(movedUTC.durationSeconds == 5_400)

        let zone = try TimeZoneID("Europe/Madrid")
        let zoned = EventTime.zoned(try ZonedEventTime(
            localStart: LocalDateTime(date: CivilDate(year: 2026, month: 9, day: 1), hour: 14, minute: 15),
            timeZone: zone,
            repeatedTime: .first,
            durationSeconds: 3_600,
            resolver: FoundationLocalTimeResolver()
        ))
        guard case let .zoned(movedZoned) = try zoned.moved(to: target) else {
            Issue.record("Expected zoned time")
            return
        }
        let expectedLocalStart = try LocalDateTime(date: target, hour: 14, minute: 15)
        #expect(movedZoned.localStart == expectedLocalStart)
        #expect(movedZoned.durationSeconds == 3_600)
    }
    @Test("all-day events use exclusive civil end dates")
    func allDayDuration() throws {
        let start = try CivilDate(year: 2026, month: 3, day: 28)
        let end = try CivilDate(year: 2026, month: 3, day: 30)
        let time = try AllDayEventTime(start: start, endExclusive: end)
        #expect(time.durationInDays == 2)
        #expect(throws: DomainValidationError.invalidRange) {
            try AllDayEventTime(start: end, endExclusive: start)
        }
    }

    @Test("timed events require positive non-overflowing duration")
    func timedDuration() throws {
        #expect(throws: DomainValidationError.invalidDuration) {
            try TimedEventTime(start: Instant(unixSeconds: 0), durationSeconds: 0)
        }
        #expect(throws: DomainValidationError.arithmeticOverflow) {
            try TimedEventTime(start: Instant(unixSeconds: Int64.max), durationSeconds: 1)
        }
        let time = try TimedEventTime(start: Instant(unixSeconds: -1), durationSeconds: 3_600)
        #expect(time.endExclusive.unixSeconds == 3_599)
    }

    @Test("calendar rename preserves stable identity and validates names")
    func calendarIdentity() throws {
        let id = UUID()
        var calendar = try LocalCalendar(id: id, name: "Personal", defaultTimeZone: TimeZoneID("Europe/Madrid"))
        try calendar.rename(to: "Private")
        #expect(calendar.id == id)
        #expect(calendar.name == "Private")
        #expect(throws: DomainValidationError.invalidCalendarName) {
            try calendar.rename(to: "  ")
        }
    }

    @Test("event text is bounded and revision advances only on valid updates")
    func eventContentAndRevision() throws {
        let calendarID = UUID()
        var event = try Event(
            calendarID: calendarID,
            title: "Review",
            time: .utc(try TimedEventTime(start: Instant(unixSeconds: 100), durationSeconds: 60))
        )
        let id = event.id
        #expect(event.uid == id.uuidString)
        #expect(event.revision == 0)
        try event.update(title: "Planning", notes: "Line 1\nLine 2", location: "Room 2", time: event.time)
        #expect(event.revision == 1)
        #expect(event.id == id)
        #expect(throws: DomainValidationError.invalidEventTitle) {
            try event.update(title: "\n", notes: nil, location: nil, time: event.time)
        }
        #expect(event.title == "Planning")
        #expect(event.revision == 1)
    }

    @Test("zoned event time resolves with explicit zone and fold policy")
    func zonedEventTime() throws {
        let local = try LocalDateTime(date: CivilDate(year: 2026, month: 10, day: 25), hour: 2, minute: 30)
        let zone = try TimeZoneID("Europe/Madrid")
        let first = try ZonedEventTime(
            localStart: local,
            timeZone: zone,
            repeatedTime: .first,
            durationSeconds: 3_600,
            resolver: FoundationLocalTimeResolver()
        )
        #expect(first.endExclusive.unixSeconds - first.resolvedStart.unixSeconds == 3_600)
    }
}
