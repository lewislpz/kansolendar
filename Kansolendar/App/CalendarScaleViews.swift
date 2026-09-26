import KansolendarCore
import KansolendarStorage
import SwiftUI

enum CalendarViewMode: String, CaseIterable, Identifiable {
    case day, week, month, year

    var id: Self { self }
    var title: String { rawValue.uppercased() }
    var systemImage: String {
        switch self {
        case .day: "rectangle.split.1x2"
        case .week: "rectangle.split.3x1"
        case .month: "calendar"
        case .year: "square.grid.3x3"
        }
    }
}

struct CalendarModeBar: View {
    @Environment(\.appAccentColor) private var accent
    @Binding var mode: CalendarViewMode

    var body: some View {
        HStack(spacing: 8) {
            Text("VIEW_MODE")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(CalendarViewMode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                        .font(.caption.monospaced().weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(mode == option ? accent : .secondary)
                        .background(mode == option ? accent.opacity(0.12) : .clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(mode == option ? accent.opacity(0.8) : Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.rawValue.capitalized) view")
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct DayCalendarView: View {
    @Environment(\.appAccentColor) private var accent
    let events: [VaultEvent]
    let calendars: [LocalCalendar]
    @Binding var selectedDate: CivilDate
    let canCreateEvent: Bool
    let onCreateEvent: (CivilDate) -> Void
    let onEditEvent: (Event) -> Void
    let onDeleteEvent: (Event) -> Void

    private var placements: [CalendarEventPlacement] {
        let grid = try! MonthGrid(month: CalendarMonth(containing: selectedDate))
        return CalendarEventPlacement.index(events: events, in: grid)[selectedDate] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            periodHeader
            ScrollView {
                LazyVStack(spacing: 8) {
                    if placements.isEmpty {
                        TechEmptyState(text: "NO EVENTS / OPEN SLOT", systemImage: "waveform.path.ecg")
                    } else {
                        ForEach(placements) { placement in
                            TechEventCard(
                                placement: placement,
                                calendar: calendars.first { $0.id == placement.master.calendarID },
                                onEdit: { onEditEvent(placement.master) },
                                onDelete: { onDeleteEvent(placement.master) }
                            )
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var periodHeader: some View {
        TechPeriodHeader(
            eyebrow: "DAY / \(selectedDate.isoWeekday)",
            title: format(selectedDate, .dateTime.weekday(.wide).month(.wide).day().year()),
            previousLabel: "Previous day",
            nextLabel: "Next day",
            onPrevious: { selectedDate = (try? selectedDate.adding(days: -1)) ?? selectedDate },
            onToday: { selectedDate = .localToday },
            onNext: { selectedDate = (try? selectedDate.adding(days: 1)) ?? selectedDate },
            onCreate: canCreateEvent ? { onCreateEvent(selectedDate) } : nil
        )
    }
}

struct WeekCalendarView: View {
    @Environment(\.appAccentColor) private var accent
    let events: [VaultEvent]
    let calendars: [LocalCalendar]
    @Binding var selectedDate: CivilDate
    let canCreateEvent: Bool
    let onCreateEvent: (CivilDate) -> Void
    let onEditEvent: (Event) -> Void

    private var weekStart: CivilDate {
        (try? selectedDate.adding(days: -(selectedDate.isoWeekday - 1))) ?? selectedDate
    }

    private var dates: [CivilDate] {
        (0..<7).compactMap { try? weekStart.adding(days: $0) }
    }

    private var indexed: [CivilDate: [CalendarEventPlacement]] {
        let grid = try! MonthGrid(month: CalendarMonth(containing: selectedDate))
        return CalendarEventPlacement.index(events: events, in: grid)
    }

    var body: some View {
        VStack(spacing: 0) {
            TechPeriodHeader(
                eyebrow: "WEEK / \(weekNumber)",
                title: weekTitle,
                previousLabel: "Previous week",
                nextLabel: "Next week",
                onPrevious: { selectedDate = (try? selectedDate.adding(days: -7)) ?? selectedDate },
                onToday: { selectedDate = .localToday },
                onNext: { selectedDate = (try? selectedDate.adding(days: 7)) ?? selectedDate },
                onCreate: canCreateEvent ? { onCreateEvent(selectedDate) } : nil
            )
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(dates, id: \.self) { date in
                        weekColumn(date)
                    }
                }
                .padding(16)
            }
        }
    }

    private func weekColumn(_ date: CivilDate) -> some View {
        let dayEvents = indexed[date] ?? []
        let isSelected = date == selectedDate
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                selectedDate = date
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(format(date, .dateTime.weekday(.abbreviated)).uppercased())
                        .font(.caption2.monospaced().weight(.bold))
                    Text("\(date.day)")
                        .font(.title2.monospaced().weight(.semibold))
                }
                .foregroundStyle(isSelected ? accent : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Divider().overlay(isSelected ? accent : Color(nsColor: .separatorColor))

            if dayEvents.isEmpty {
                Text("OPEN")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            } else {
                ForEach(dayEvents) { placement in
                    TechWeekEvent(
                        placement: placement,
                        color: calendars.first { $0.id == placement.master.calendarID }?.color.swiftUIColor ?? accent,
                        onEdit: { onEditEvent(placement.master) }
                    )
                }
            }
            Spacer(minLength: 80)
        }
        .padding(10)
        .frame(width: 156)
        .frame(minHeight: 430, alignment: .topLeading)
        .background(isSelected ? accent.opacity(0.07) : Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(isSelected ? accent : Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedDate = date }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard canCreateEvent else { return }
            selectedDate = date
            onCreateEvent(date)
        })
    }

    private var weekTitle: String {
        guard let end = dates.last else { return "" }
        return "\(format(weekStart, .dateTime.month(.abbreviated).day())) — \(format(end, .dateTime.month(.abbreviated).day().year()))"
    }

    private var weekNumber: Int {
        Calendar(identifier: .iso8601).component(.weekOfYear, from: MonthCalendarView.foundationDate(selectedDate))
    }
}

struct YearCalendarView: View {
    @Environment(\.appAccentColor) private var accent
    let events: [VaultEvent]
    @Binding var selectedDate: CivilDate
    let canCreateEvent: Bool
    let onCreateEvent: (CivilDate) -> Void

    private let columns = Array(repeating: GridItem(.flexible(minimum: 230), spacing: 12), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            TechPeriodHeader(
                eyebrow: "YEAR / 12 MONTHS",
                title: selectedDate.year.formatted(),
                previousLabel: "Previous year",
                nextLabel: "Next year",
                onPrevious: { setYear(selectedDate.year - 1) },
                onToday: { selectedDate = .localToday },
                onNext: { setYear(selectedDate.year + 1) },
                onCreate: nil
            )
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(1...12, id: \.self) { month in
                        MiniMonthPanel(
                            year: selectedDate.year,
                            month: month,
                            events: events,
                            selectedDate: $selectedDate,
                            canCreateEvent: canCreateEvent,
                            onCreateEvent: onCreateEvent
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private func setYear(_ year: Int) {
        guard (1...9999).contains(year), let date = try? CivilDate(year: year, month: 1, day: 1) else { return }
        selectedDate = date
    }
}

private struct MiniMonthPanel: View {
    @Environment(\.appAccentColor) private var accent
    let year: Int
    let month: Int
    let events: [VaultEvent]
    @Binding var selectedDate: CivilDate
    let canCreateEvent: Bool
    let onCreateEvent: (CivilDate) -> Void

    private var calendarMonth: CalendarMonth { try! CalendarMonth(year: year, month: month) }
    private var grid: MonthGrid { try! MonthGrid(month: calendarMonth) }
    private var indexed: [CivilDate: [CalendarEventPlacement]] { CalendarEventPlacement.index(events: events, in: grid) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(format(calendarMonth.firstDay, .dateTime.month(.wide)).uppercased())
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(accent)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                ForEach(grid.days) { day in
                    Button {
                        selectedDate = day.date
                    } label: {
                        ZStack(alignment: .bottom) {
                            Text("\(day.date.day)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(day.isInDisplayedMonth ? .primary : .tertiary)
                                .frame(maxWidth: .infinity, minHeight: 22)
                                .background(day.date == selectedDate ? accent.opacity(0.16) : .clear)
                            if !(indexed[day.date] ?? []).isEmpty, day.isInDisplayedMonth {
                                Circle().fill(accent).frame(width: 3, height: 3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        guard canCreateEvent else { return }
                        selectedDate = day.date
                        onCreateEvent(day.date)
                    })
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 1) }
    }
}

private struct TechPeriodHeader: View {
    @Environment(\.appAccentColor) private var accent
    let eyebrow: String
    let title: String
    let previousLabel: String
    let nextLabel: String
    let onPrevious: () -> Void
    let onToday: () -> Void
    let onNext: () -> Void
    let onCreate: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(accent)
                Text(title.uppercased())
                    .font(.title2.monospaced().weight(.semibold))
            }
            Spacer()
            Button(previousLabel, systemImage: "chevron.left", action: onPrevious).labelStyle(.iconOnly)
            Button("Today", action: onToday)
            Button(nextLabel, systemImage: "chevron.right", action: onNext).labelStyle(.iconOnly)
            if let onCreate {
                Button("New Event", systemImage: "plus", action: onCreate)
                    .buttonStyle(.borderedProminent)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .overlay(alignment: .bottom) { Rectangle().fill(accent.opacity(0.45)).frame(height: 1) }
    }
}

private struct TechEmptyState: View {
    @Environment(\.appAccentColor) private var accent
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(accent)
            Text(text).font(.callout.monospaced()).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(accent.opacity(0.25), lineWidth: 1) }
    }
}

private struct TechEventCard: View {
    @Environment(\.appAccentColor) private var accent
    let placement: CalendarEventPlacement
    let calendar: LocalCalendar?
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Rectangle()
                .fill(calendar?.color.swiftUIColor ?? accent)
                .frame(width: 3, height: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(placement.timeDescription.uppercased())
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(accent)
                Text(placement.master.title).font(.headline)
                if let location = placement.master.location {
                    Text(location).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Edit", systemImage: "pencil", action: onEdit).labelStyle(.iconOnly)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete).labelStyle(.iconOnly)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 1) }
    }
}

private struct TechWeekEvent: View {
    let placement: CalendarEventPlacement
    let color: Color
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 3) {
                Text(placement.timeDescription.uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(placement.master.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(color.opacity(0.13))
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
        }
        .buttonStyle(.plain)
    }
}

private func format(_ date: CivilDate, _ style: Date.FormatStyle) -> String {
    MonthCalendarView.foundationDate(date).formatted(style.locale(Locale(identifier: "en_US")))
}
