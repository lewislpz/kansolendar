import Foundation
@testable import KansolendarCore
import Testing

@Suite("iCalendar codec")
struct ICalendarCodecTests {
    @Test("exports and imports supported all-day and UTC events")
    func roundTrip() throws {
        let calendarID = UUID()
        let allDay = try Event(
            calendarID: calendarID,
            uid: "all-day@example",
            title: "Release, day",
            notes: "Line one\nLine two",
            location: "Lab; A",
            time: .allDay(try AllDayEventTime(
                start: CivilDate(year: 2026, month: 9, day: 26),
                endExclusive: CivilDate(year: 2026, month: 9, day: 27)
            ))
        )
        let timed = try Event(
            calendarID: calendarID,
            uid: "utc@example",
            title: "UTC event",
            time: .utc(try TimedEventTime(start: Instant(unixSeconds: 1_800_000_000), durationSeconds: 3_600))
        )

        let data = try ICalendarCodec.encode(events: [allDay, timed])
        let decoded = try ICalendarCodec.decode(data, calendarID: calendarID)

        #expect(decoded.map(\.uid) == [allDay.uid, timed.uid])
        #expect(decoded.map(\.title) == [allDay.title, timed.title])
        #expect(decoded.map(\.time) == [allDay.time, timed.time])
        #expect(decoded[0].notes == allDay.notes)
        #expect(decoded[0].location == allDay.location)
    }

    @Test("rejects unsupported semantic properties")
    func rejectsUnsupported() {
        let text = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        BEGIN:VEVENT\r
        UID:a\r
        SUMMARY:Unsafe\r
        DTSTART:20260926T120000Z\r
        DTEND:20260926T130000Z\r
        ATTACH:https://example.test/file\r
        END:VEVENT\r
        END:VCALENDAR\r

        """
        #expect(throws: ICalendarCodecError.unsupported) {
            try ICalendarCodec.decode(Data(text.utf8), calendarID: UUID())
        }
    }

    @Test("rejects oversized input before parsing")
    func rejectsOversized() {
        #expect(throws: ICalendarCodecError.limitExceeded) {
            try ICalendarCodec.decode(
                Data(repeating: 0x41, count: ICalendarCodec.maximumBytes + 1),
                calendarID: UUID()
            )
        }
    }
}
