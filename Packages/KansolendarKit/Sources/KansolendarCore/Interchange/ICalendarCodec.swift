import Foundation

public enum ICalendarCodecError: Error, Equatable, Sendable {
    case malformed
    case unsupported
    case limitExceeded
}

public enum ICalendarCodec {
    public static let maximumBytes = 10 * 1_024 * 1_024
    public static let maximumEvents = 10_000
    private static let maximumUnfoldedLineBytes = 256 * 1_024
    private static let maximumPropertiesPerEvent = 512

    public static func encode(events: [Event]) throws -> Data {
        guard events.count <= maximumEvents else { throw ICalendarCodecError.limitExceeded }
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Kansolendar//Local Calendar 1.0//EN",
            "CALSCALE:GREGORIAN"
        ]
        for event in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(escape(event.uid))")
            lines.append("DTSTAMP:\(formatUTC(Instant(unixSeconds: 0)))")
            lines.append("SUMMARY:\(escape(event.title))")
            if let notes = event.notes { lines.append("DESCRIPTION:\(escape(notes))") }
            if let location = event.location { lines.append("LOCATION:\(escape(location))") }
            switch event.time {
            case let .allDay(value):
                lines.append("DTSTART;VALUE=DATE:\(formatDate(value.range.start))")
                lines.append("DTEND;VALUE=DATE:\(formatDate(value.range.endExclusive))")
            case let .utc(value):
                lines.append("DTSTART:\(formatUTC(value.start))")
                lines.append("DTEND:\(formatUTC(value.endExclusive))")
            case let .zoned(value):
                lines.append("DTSTART:\(formatUTC(value.resolvedStart))")
                lines.append("DTEND:\(formatUTC(value.endExclusive))")
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        let text = lines.map(fold).joined(separator: "\r\n") + "\r\n"
        guard let data = text.data(using: .utf8), data.count <= maximumBytes else {
            throw ICalendarCodecError.limitExceeded
        }
        return data
    }

    public static func decode(_ data: Data, calendarID: UUID) throws -> [Event] {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = String(data: data, encoding: .utf8) else {
            throw data.count > maximumBytes
                ? ICalendarCodecError.limitExceeded
                : ICalendarCodecError.malformed
        }
        let physical = source.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var lines: [String] = []
        for raw in physical {
            let line = String(raw)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !lines.isEmpty else { throw ICalendarCodecError.malformed }
                lines[lines.count - 1] += String(line.dropFirst())
            } else if !line.isEmpty {
                lines.append(line)
            }
            if let last = lines.last, last.utf8.count > maximumUnfoldedLineBytes {
                throw ICalendarCodecError.limitExceeded
            }
        }
        guard lines.first == "BEGIN:VCALENDAR", lines.last == "END:VCALENDAR",
              lines.contains("VERSION:2.0") else { throw ICalendarCodecError.malformed }

        var events: [Event] = []
        var index = 1
        while index < lines.count - 1 {
            if lines[index] == "BEGIN:VEVENT" {
                var properties: [String: String] = [:]
                index += 1
                var count = 0
                while index < lines.count, lines[index] != "END:VEVENT" {
                    count += 1
                    guard count <= maximumPropertiesPerEvent else { throw ICalendarCodecError.limitExceeded }
                    let (name, value) = try property(lines[index])
                    guard properties.updateValue(value, forKey: name) == nil else {
                        throw ICalendarCodecError.unsupported
                    }
                    index += 1
                }
                guard index < lines.count, lines[index] == "END:VEVENT" else {
                    throw ICalendarCodecError.malformed
                }
                events.append(try makeEvent(properties, calendarID: calendarID))
                guard events.count <= maximumEvents else { throw ICalendarCodecError.limitExceeded }
            } else {
                let (name, _) = try property(lines[index])
                guard ["VERSION", "PRODID", "CALSCALE"].contains(name) else {
                    throw ICalendarCodecError.unsupported
                }
            }
            index += 1
        }
        return events
    }

    private static func makeEvent(_ values: [String: String], calendarID: UUID) throws -> Event {
        let allowed = Set(["UID", "DTSTAMP", "SUMMARY", "DESCRIPTION", "LOCATION", "DTSTART", "DTSTART;VALUE=DATE", "DTEND", "DTEND;VALUE=DATE"])
        guard Set(values.keys).isSubset(of: allowed),
              let uid = values["UID"], !uid.isEmpty,
              let summary = values["SUMMARY"] else { throw ICalendarCodecError.unsupported }
        let title = try unescape(summary)
        let notes = try values["DESCRIPTION"].map(unescape)
        let location = try values["LOCATION"].map(unescape)
        let time: EventTime
        if let start = values["DTSTART;VALUE=DATE"], let end = values["DTEND;VALUE=DATE"],
           values["DTSTART"] == nil, values["DTEND"] == nil {
            time = .allDay(try AllDayEventTime(start: parseDate(start), endExclusive: parseDate(end)))
        } else if let start = values["DTSTART"], let end = values["DTEND"],
                  values["DTSTART;VALUE=DATE"] == nil, values["DTEND;VALUE=DATE"] == nil {
            let startInstant = try parseUTC(start)
            let endInstant = try parseUTC(end)
            let duration = endInstant.unixSeconds.subtractingReportingOverflow(startInstant.unixSeconds)
            guard !duration.overflow else { throw ICalendarCodecError.malformed }
            time = .utc(try TimedEventTime(start: startInstant, durationSeconds: duration.partialValue))
        } else {
            throw ICalendarCodecError.unsupported
        }
        do {
            return try Event(
                calendarID: calendarID,
                uid: try unescape(uid),
                title: title,
                notes: notes,
                location: location,
                time: time
            )
        } catch is DomainValidationError {
            throw ICalendarCodecError.malformed
        }
    }

    private static func property(_ line: String) throws -> (String, String) {
        guard let separator = line.firstIndex(of: ":") else { throw ICalendarCodecError.malformed }
        let name = String(line[..<separator]).uppercased()
        let value = String(line[line.index(after: separator)...])
        guard !name.isEmpty else { throw ICalendarCodecError.malformed }
        return (name, value)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    private static func unescape(_ value: String) throws -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "n", "N": result.append("\n")
                case "\\", ",", ";": result.append(character)
                default: throw ICalendarCodecError.malformed
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        guard !escaped else { throw ICalendarCodecError.malformed }
        return result
    }

    private static func fold(_ line: String) -> String {
        var output = ""
        var width = 0
        for scalar in line.unicodeScalars {
            let bytes = String(scalar).utf8.count
            if width + bytes > 75 {
                output += "\r\n "
                width = 1
            }
            output.unicodeScalars.append(scalar)
            width += bytes
        }
        return output
    }

    private static func formatDate(_ date: CivilDate) -> String {
        String(format: "%04d%02d%02d", date.year, date.month, date.day)
    }

    private static func parseDate(_ value: String) throws -> CivilDate {
        guard value.count == 8, value.allSatisfy(\.isNumber),
              let year = Int(value.prefix(4)),
              let month = Int(value.dropFirst(4).prefix(2)),
              let day = Int(value.suffix(2)) else { throw ICalendarCodecError.malformed }
        do { return try CivilDate(year: year, month: month, day: day) }
        catch { throw ICalendarCodecError.malformed }
    }

    private static func formatUTC(_ instant: Instant) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(instant.unixSeconds))
        return utcFormatter.string(from: date)
    }

    private static func parseUTC(_ value: String) throws -> Instant {
        guard value.count == 16, value.hasSuffix("Z"), let date = utcFormatter.date(from: value) else {
            throw ICalendarCodecError.unsupported
        }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds.rounded() == seconds,
              seconds >= Double(Int64.min), seconds <= Double(Int64.max) else {
            throw ICalendarCodecError.malformed
        }
        return Instant(unixSeconds: Int64(seconds))
    }

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.isLenient = false
        return formatter
    }()
}
