import Foundation

public struct AllDayEventTime: Hashable, Sendable {
    public let range: CivilDateRange

    public init(start: CivilDate, endExclusive: CivilDate) throws {
        self.range = try CivilDateRange(start: start, endExclusive: endExclusive)
    }

    public var durationInDays: Int64 { range.dayCount }
}

public struct TimedEventTime: Hashable, Sendable {
    public let start: Instant
    public let endExclusive: Instant
    public let durationSeconds: Int64

    public init(start: Instant, durationSeconds: Int64) throws {
        guard durationSeconds > 0 else { throw DomainValidationError.invalidDuration }
        let endExclusive = try start.adding(seconds: durationSeconds)
        self.start = start
        self.endExclusive = endExclusive
        self.durationSeconds = durationSeconds
    }

    public var range: InstantRange {
        // The constructor guarantees a positive duration and representable end.
        InstantRange(uncheckedStart: start, endExclusive: endExclusive)
    }
}

public struct ZonedEventTime: Hashable, Sendable {
    public let localStart: LocalDateTime
    public let timeZone: TimeZoneID
    public let resolvedStart: Instant
    public let endExclusive: Instant
    public let repeatedTime: RepeatedTimeChoice
    public let durationSeconds: Int64

    public init(
        localStart: LocalDateTime,
        timeZone: TimeZoneID,
        repeatedTime: RepeatedTimeChoice,
        durationSeconds: Int64,
        resolver: some LocalTimeResolving
    ) throws {
        guard durationSeconds > 0 else { throw DomainValidationError.invalidDuration }
        let resolvedStart = try resolver.resolve(localStart, in: timeZone, repeatedTime: repeatedTime)
        let endExclusive = try resolvedStart.adding(seconds: durationSeconds)
        self.localStart = localStart
        self.timeZone = timeZone
        self.resolvedStart = resolvedStart
        self.endExclusive = endExclusive
        self.repeatedTime = repeatedTime
        self.durationSeconds = durationSeconds
    }

    public var instantRange: InstantRange {
        InstantRange(uncheckedStart: resolvedStart, endExclusive: endExclusive)
    }
}

public enum EventTime: Hashable, Sendable {
    case allDay(AllDayEventTime)
    case utc(TimedEventTime)
    case zoned(ZonedEventTime)

    public var durationSeconds: Int64? {
        switch self {
        case .allDay: nil
        case let .utc(value): value.durationSeconds
        case let .zoned(value): value.durationSeconds
        }
    }

    /// Moves an event to another civil day while preserving its duration and clock semantics.
    /// UTC values retain their UTC time of day; zoned values retain their wall-clock time and zone.
    public func moved(
        to date: CivilDate,
        resolver: some LocalTimeResolving = FoundationLocalTimeResolver()
    ) throws -> Self {
        switch self {
        case let .allDay(value):
            guard let duration = Int(exactly: value.durationInDays) else {
                throw DomainValidationError.arithmeticOverflow
            }
            return .allDay(try AllDayEventTime(start: date, endExclusive: date.adding(days: duration)))
        case let .utc(value):
            var secondsInDay = value.start.unixSeconds % 86_400
            if secondsInDay < 0 { secondsInDay += 86_400 }
            let daySeconds = date.daysSinceUnixEpoch.multipliedReportingOverflow(by: 86_400)
            guard !daySeconds.overflow else { throw DomainValidationError.arithmeticOverflow }
            let start = daySeconds.partialValue.addingReportingOverflow(secondsInDay)
            guard !start.overflow else { throw DomainValidationError.arithmeticOverflow }
            return .utc(try TimedEventTime(
                start: Instant(unixSeconds: start.partialValue),
                durationSeconds: value.durationSeconds
            ))
        case let .zoned(value):
            let localStart = try LocalDateTime(
                date: date,
                hour: value.localStart.hour,
                minute: value.localStart.minute,
                second: value.localStart.second
            )
            return .zoned(try ZonedEventTime(
                localStart: localStart,
                timeZone: value.timeZone,
                repeatedTime: value.repeatedTime,
                durationSeconds: value.durationSeconds,
                resolver: resolver
            ))
        }
    }
}

public enum EventTimeRange: Hashable, Sendable {
    case civil(CivilDateRange)
    case instant(InstantRange)
}

public enum EventStart: Hashable, Sendable {
    case civil(CivilDate)
    case instant(Instant)
    case zoned(LocalDateTime, TimeZoneID)
}

extension EventStart {
    func matches(kindOf anchor: Self) -> Bool {
        switch (self, anchor) {
        case (.civil, .civil), (.instant, .instant): true
        case let (.zoned(_, zone), .zoned(_, anchorZone)): zone == anchorZone
        default: false
        }
    }
}

public struct EventOccurrenceKey: Hashable, Sendable {
    public let eventID: UUID
    public let originalStart: EventStart

    public init(eventID: UUID, originalStart: EventStart) {
        self.eventID = eventID
        self.originalStart = originalStart
    }
}

public struct EventCancellation: Hashable, Sendable {
    public let key: EventOccurrenceKey

    public init(key: EventOccurrenceKey) {
        self.key = key
    }
}
