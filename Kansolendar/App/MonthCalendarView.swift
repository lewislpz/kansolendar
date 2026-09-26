import KansolendarCore
import KansolendarStorage
import SwiftUI

struct MonthCalendarView: View {
    @Environment(\.appAccentColor) private var appAccentColor
    let events: [VaultEvent]
    let calendars: [LocalCalendar]
    @Binding var displayedMonth: CalendarMonth
    @Binding var selectedDate: CivilDate
    let canCreateEvent: Bool
    let onCreateEvent: (CivilDate) -> Void
    let onEditEvent: (Event) -> Void
    let onDeleteEvent: (Event) -> Void
    let onMoveEvent: (UUID, CivilDate) -> Void

    private let columns = Array(repeating: GridItem(.flexible(minimum: 88), spacing: 0), count: 7)

    private var grid: MonthGrid {
        // Displayed months originate from a valid CivilDate and navigation is bounded.
        try! MonthGrid(month: displayedMonth)
    }

    private var placements: [CivilDate: [CalendarEventPlacement]] {
        CalendarEventPlacement.index(events: events, in: grid)
    }

    var body: some View {
        VStack(spacing: 0) {
            monthHeader
            if !canCreateEvent {
                Label {
                    Text("Create a calendar in the sidebar to start adding events.")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(appAccentColor)
                }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(appAccentColor.opacity(0.06))
            }
            weekdayHeader
            ScrollView {
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(grid.days) { day in
                        dayCell(day)
                    }
                }
                .background(Color(nsColor: .separatorColor).opacity(0.45))

                selectedDayAgenda
                    .padding(.top, 18)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var monthHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(monthName.uppercased())
                    .font(.system(.title, design: .monospaced, weight: .semibold))
                    .tracking(1.4)
            }

            Spacer()

            Button("Previous month", systemImage: "chevron.left") { moveMonth(by: -1) }
                .labelStyle(.iconOnly)
            Button("Today") { selectToday() }
            Button("Next month", systemImage: "chevron.right") { moveMonth(by: 1) }
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Self.weekdaySymbols, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func dayCell(_ day: MonthGridDay) -> some View {
        let dayEvents = placements[day.date] ?? []
        let isSelected = day.date == selectedDate
        let isToday = day.date == .localToday

        return Button {
            selectedDate = day.date
            if !day.isInDisplayedMonth { displayedMonth = CalendarMonth(containing: day.date) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(day.date.day.formatted())
                        .font(.system(.callout, design: .monospaced, weight: isToday ? .bold : .medium))
                        .foregroundStyle(isToday ? Color.white : (day.isInDisplayedMonth ? Color.primary : Color.secondary.opacity(0.55)))
                        .frame(width: 25, height: 25)
                        .background(isToday ? appAccentColor : .clear, in: Circle())
                    Spacer()
                    if !dayEvents.isEmpty {
                        Text("\(dayEvents.count)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(dayEvents.prefix(3)) { placement in
                    EventChip(
                        placement: placement,
                        calendar: calendars.first { $0.id == placement.master.calendarID }
                    )
                }
                if dayEvents.count > 3 {
                    Text("+\(dayEvents.count - 3) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 112, alignment: .topLeading)
            .background(isSelected ? appAccentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
            .overlay {
                Rectangle()
                    .stroke(isSelected ? appAccentColor : Color(nsColor: .separatorColor).opacity(0.45), lineWidth: isSelected ? 1.5 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayAccessibilityLabel(day.date, count: dayEvents.count))
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard canCreateEvent else { return }
            selectedDate = day.date
            onCreateEvent(day.date)
        })
        .dropDestination(for: String.self) { identifiers, _ in
            guard let rawID = identifiers.first, let eventID = UUID(uuidString: rawID) else { return false }
            selectedDate = day.date
            onMoveEvent(eventID, day.date)
            return true
        }
        .contextMenu {
            Button("New event on \(shortDate(day.date))") { onCreateEvent(day.date) }
                .disabled(!canCreateEvent)
        }
    }

    private var selectedDayAgenda: some View {
        let selectedEvents = placements[selectedDate] ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AGENDA / \(shortDate(selectedDate).uppercased())")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(appAccentColor)
                    Text(longDate(selectedDate))
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                Button("New Event", systemImage: "plus") { onCreateEvent(selectedDate) }
                    .buttonStyle(.borderedProminent)
                    .tint(appAccentColor)
                    .disabled(!canCreateEvent)
            }

            if selectedEvents.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(appAccentColor)
                    Text("No activity scheduled for this day.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(selectedEvents) { placement in
                    AgendaRow(
                        placement: placement,
                        calendar: calendars.first { $0.id == placement.master.calendarID },
                        onEdit: { onEditEvent(placement.master) },
                        onDelete: { onDeleteEvent(placement.master) }
                    )
                }
            }
        }
    }

    private var monthName: String {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = displayedMonth.year
        components.month = displayedMonth.month
        components.day = 1
        return components.date?.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US")))
            ?? "\(displayedMonth.month)/\(displayedMonth.year)"
    }

    private func moveMonth(by delta: Int) {
        guard let month = try? displayedMonth.adding(months: delta) else { return }
        displayedMonth = month
        selectedDate = month.firstDay
    }

    private func selectToday() {
        selectedDate = .localToday
        displayedMonth = CalendarMonth(containing: selectedDate)
    }

    private func shortDate(_ date: CivilDate) -> String {
        Self.foundationDate(date).formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US")))
    }

    private func longDate(_ date: CivilDate) -> String {
        Self.foundationDate(date).formatted(.dateTime.weekday(.wide).month(.wide).day().locale(Locale(identifier: "en_US")))
    }

    private func dayAccessibilityLabel(_ date: CivilDate, count: Int) -> String {
        "\(longDate(date)), \(count) \(count == 1 ? "event" : "events")"
    }

    private static var weekdaySymbols: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return Array(symbols[1...]) + [symbols[0]]
    }

    nonisolated static func foundationDate(_ date: CivilDate) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .autoupdatingCurrent
        components.year = date.year
        components.month = date.month
        components.day = date.day
        return components.date ?? .distantPast
    }
}

private struct EventChip: View {
    @Environment(\.appAccentColor) private var appAccentColor
    let placement: CalendarEventPlacement
    let calendar: LocalCalendar?

    var body: some View {
        if placement.isRecurring {
            chip
        } else {
            chip.draggable(placement.master.id.uuidString) {
                chip.frame(width: 180)
            }
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(calendar?.color.swiftUIColor ?? appAccentColor)
                .frame(width: 3)
            Text(placement.master.title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((calendar?.color.swiftUIColor ?? appAccentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct AgendaRow: View {
    @Environment(\.appAccentColor) private var appAccentColor
    let placement: CalendarEventPlacement
    let calendar: LocalCalendar?
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(calendar?.color.swiftUIColor ?? appAccentColor)
                .frame(width: 4, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(placement.master.title).font(.headline)
                Text(placement.timeDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let location = placement.master.location {
                Label(location, systemImage: "mappin")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Edit", systemImage: "pencil", action: onEdit)
                .labelStyle(.iconOnly)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct CalendarEventPlacement: Identifiable {
    let master: Event
    let occurrenceTime: EventTime
    let day: CivilDate
    let isRecurring: Bool

    var id: String { "\(master.id.uuidString):\(day.daysSinceUnixEpoch):\(timeKey)" }

    var timeDescription: String {
        switch occurrenceTime {
        case .allDay:
            "All day"
        case let .utc(value):
            Date(timeIntervalSince1970: TimeInterval(value.start.unixSeconds)).formatted(date: .omitted, time: .shortened)
        case let .zoned(value):
            Date(timeIntervalSince1970: TimeInterval(value.resolvedStart.unixSeconds)).formatted(date: .omitted, time: .shortened)
        }
    }

    private var timeKey: String {
        switch occurrenceTime {
        case let .allDay(value): "d\(value.range.start.daysSinceUnixEpoch)"
        case let .utc(value): "u\(value.start.unixSeconds)"
        case let .zoned(value): "z\(value.resolvedStart.unixSeconds)"
        }
    }

    static func index(events: [VaultEvent], in grid: MonthGrid) -> [CivilDate: [Self]] {
        var result: [CivilDate: [Self]] = [:]
        for stored in events {
            for time in occurrenceTimes(for: stored, grid: grid) {
                for day in grid.days where overlaps(time, day: day.date) {
                    result[day.date, default: []].append(Self(
                        master: stored.event,
                        occurrenceTime: time,
                        day: day.date,
                        isRecurring: stored.recurrence != nil
                    ))
                }
            }
        }
        for day in result.keys {
            result[day]?.sort { lhs, rhs in
                (sortKey(lhs.occurrenceTime), lhs.master.title) < (sortKey(rhs.occurrenceTime), rhs.master.title)
            }
        }
        return result
    }

    private static func occurrenceTimes(for stored: VaultEvent, grid: MonthGrid) -> [EventTime] {
        guard let recurrence = stored.recurrence,
              let series = try? RecurringSeries(event: stored.event, rule: recurrence, cancellations: stored.cancellations) else {
            return [stored.event.time]
        }
        let query: EventTimeRange
        switch stored.event.time {
        case .allDay:
            query = .civil(grid.range)
        case .utc, .zoned:
            let start = MonthCalendarView.foundationDate(grid.range.start)
            let end = MonthCalendarView.foundationDate(grid.range.endExclusive)
            guard let range = try? InstantRange(
                start: Instant(unixSeconds: Int64(start.timeIntervalSince1970)),
                endExclusive: Instant(unixSeconds: Int64(end.timeIntervalSince1970))
            ) else { return [] }
            query = .instant(range)
        }
        return (try? RecurrenceEngine().expand(series, in: query).map(\.time)) ?? []
    }

    private static func overlaps(_ time: EventTime, day: CivilDate) -> Bool {
        switch time {
        case let .allDay(value):
            return value.range.contains(day)
        case let .utc(value):
            return overlaps(start: value.start, end: value.endExclusive, day: day)
        case let .zoned(value):
            return overlaps(start: value.resolvedStart, end: value.endExclusive, day: day)
        }
    }

    private static func overlaps(start: Instant, end: Instant, day: CivilDate) -> Bool {
        let dayStart = MonthCalendarView.foundationDate(day)
        guard let dayEnd = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        let eventStart = Date(timeIntervalSince1970: TimeInterval(start.unixSeconds))
        let eventEnd = Date(timeIntervalSince1970: TimeInterval(end.unixSeconds))
        return eventStart < dayEnd && eventEnd > dayStart
    }

    private static func sortKey(_ time: EventTime) -> Int64 {
        switch time {
        case .allDay: Int64.min
        case let .utc(value): value.start.unixSeconds
        case let .zoned(value): value.resolvedStart.unixSeconds
        }
    }
}

extension CivilDate {
    static var localToday: CivilDate {
        let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: Date())
        return try! CivilDate(year: components.year!, month: components.month!, day: components.day!)
    }
}
