import KansolendarCore
import KansolendarStorage
import SwiftUI

struct CalendarWorkspaceView: View {
    @Bindable var model: VaultViewModel
    @State private var selectedCalendarID: UUID?
    @State private var editorEvent: Event?
    @State private var isPresentingEventEditor = false
    @State private var isPresentingCalendarEditor = false
    @State private var eventPendingDeletion: Event?
    @State private var searchText = ""

    private var visibleEvents: [VaultEvent] {
        let calendarEvents = selectedCalendarID.map { calendarID in
            model.events.filter { $0.event.calendarID == calendarID }
        } ?? model.events
        let needle = EventSearch.normalized(searchText)
        guard !needle.isEmpty else { return calendarEvents }
        return calendarEvents.filter { EventSearch.normalized($0.event.title).contains(needle) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedCalendarID) {
                Label("Todos los eventos", systemImage: "calendar")
                    .tag(nil as UUID?)

                Section("Calendarios") {
                    ForEach(model.calendars) { calendar in
                        Label {
                            Text(calendar.name)
                        } icon: {
                            Circle()
                                .fill(calendar.color.swiftUIColor)
                                .frame(width: 9, height: 9)
                        }
                        .tag(calendar.id as UUID?)
                    }
                }
            }
            .navigationTitle("Kansolendar")
            .safeAreaInset(edge: .bottom) {
                Button("Nuevo calendario", systemImage: "plus") {
                    isPresentingCalendarEditor = true
                }
                .buttonStyle(.plain)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 210)
        } detail: {
            eventList
        }
        .frame(minWidth: 760, minHeight: 500)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Buscar por título")
        .toolbar {
            ToolbarItemGroup {
                Button("Nuevo evento", systemImage: "plus") {
                    editorEvent = nil
                    isPresentingEventEditor = true
                }
                .disabled(model.calendars.isEmpty)
                .keyboardShortcut("n", modifiers: .command)

                Button("Bloquear", systemImage: "lock") {
                    model.lock()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        .task { await model.loadContent() }
        .sheet(isPresented: $isPresentingCalendarEditor) {
            CalendarEditorSheet(model: model)
        }
        .sheet(isPresented: $isPresentingEventEditor) {
            EventEditorSheet(
                model: model,
                event: editorEvent,
                preferredCalendarID: selectedCalendarID
            )
        }
        .alert("¿Eliminar este evento?", isPresented: deletionAlertBinding, presenting: eventPendingDeletion) { event in
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar", role: .destructive) {
                Task { _ = await model.deleteEvent(id: event.id) }
            }
        } message: { event in
            Text("“\(event.title)” se eliminará de esta bóveda.")
        }
    }

    private var eventList: some View {
        Group {
            if model.isLoadingContent {
                ProgressView("Cargando eventos…")
            } else if model.calendars.isEmpty {
                ContentUnavailableView {
                    Label("Crea tu primer calendario", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Después podrás añadir citas privadas guardadas solo en este Mac.")
                } actions: {
                    Button("Crear calendario") { isPresentingCalendarEditor = true }
                }
            } else if visibleEvents.isEmpty {
                ContentUnavailableView {
                    Label("No hay eventos", systemImage: "calendar")
                } description: {
                    Text("Añade una cita para empezar.")
                } actions: {
                    Button("Nuevo evento") {
                        editorEvent = nil
                        isPresentingEventEditor = true
                    }
                }
            } else {
                List(visibleEvents, id: \.event.id) { stored in
                    EventRow(
                        event: stored.event,
                        calendar: model.calendars.first { $0.id == stored.event.calendarID }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editorEvent = stored.event
                        isPresentingEventEditor = true
                    }
                    .contextMenu {
                        Button("Editar") {
                            editorEvent = stored.event
                            isPresentingEventEditor = true
                        }
                        Button("Eliminar", role: .destructive) {
                            eventPendingDeletion = stored.event
                        }
                    }
                }
            }
        }
        .navigationTitle(selectedCalendarName)
        .overlay(alignment: .bottom) {
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .accessibilityIdentifier("workspace-message")
            }
        }
    }

    private var selectedCalendarName: String {
        guard let selectedCalendarID,
              let calendar = model.calendars.first(where: { $0.id == selectedCalendarID }) else {
            return "Eventos"
        }
        return calendar.name
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { eventPendingDeletion != nil },
            set: { if !$0 { eventPendingDeletion = nil } }
        )
    }
}

private struct EventRow: View {
    let event: Event
    let calendar: LocalCalendar?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(calendar?.color.swiftUIColor ?? .secondary)
                .frame(width: 5, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(timeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let location = event.location {
                Label(location, systemImage: "mappin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var timeDescription: String {
        let start = VaultViewModel.startDate(for: event)
        if VaultViewModel.isAllDay(event) {
            return start.formatted(date: .abbreviated, time: .omitted) + " · Todo el día"
        }
        return start.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct CalendarEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: VaultViewModel
    @State private var name = ""
    @State private var color: CalendarColor = .blue
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Nuevo calendario")
                .font(.title2.bold())
            TextField("Nombre", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Color", selection: $color) {
                ForEach(CalendarColor.allCases, id: \.self) { option in
                    Label(option.localizedName, systemImage: "circle.fill")
                        .foregroundStyle(option.swiftUIColor)
                        .tag(option)
                }
            }
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                Button("Crear") {
                    isSaving = true
                    Task {
                        if await model.createCalendar(name: name, color: color) { dismiss() }
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

private struct EventEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: VaultViewModel
    let event: Event?
    @State private var calendarID: UUID
    @State private var title: String
    @State private var notes: String
    @State private var location: String
    @State private var start: Date
    @State private var end: Date
    @State private var isAllDay: Bool
    @State private var isSaving = false

    init(model: VaultViewModel, event: Event?, preferredCalendarID: UUID?) {
        self.model = model
        self.event = event
        let initialCalendarID = event?.calendarID ?? preferredCalendarID ?? model.calendars.first?.id ?? UUID()
        _calendarID = State(initialValue: initialCalendarID)
        _title = State(initialValue: event?.title ?? "")
        _notes = State(initialValue: event?.notes ?? "")
        _location = State(initialValue: event?.location ?? "")
        let initialStart = event.map(VaultViewModel.startDate(for:)) ?? Date()
        _start = State(initialValue: initialStart)
        _end = State(initialValue: event.map(VaultViewModel.endDate(for:)) ?? initialStart.addingTimeInterval(3_600))
        _isAllDay = State(initialValue: event.map(VaultViewModel.isAllDay) ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(event == nil ? "Nuevo evento" : "Editar evento")
                .font(.title2.bold())

            Form {
                TextField("Título", text: $title)
                Picker("Calendario", selection: $calendarID) {
                    ForEach(model.calendars) { calendar in
                        Text(calendar.name).tag(calendar.id)
                    }
                }
                .disabled(event != nil)
                Toggle("Todo el día", isOn: $isAllDay)
                DatePicker("Inicio", selection: $start, displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])
                DatePicker("Fin", selection: $end, in: start..., displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])
                TextField("Ubicación", text: $location)
                TextField("Notas", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            }

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                Button("Guardar") {
                    isSaving = true
                    Task {
                        if await model.saveEvent(
                            existing: event,
                            calendarID: calendarID,
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            notes: notes,
                            location: location,
                            start: start,
                            end: end,
                            isAllDay: isAllDay
                        ) { dismiss() }
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start || isSaving)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onChange(of: isAllDay) { _, enabled in
            guard enabled, Calendar.autoupdatingCurrent.isDate(start, inSameDayAs: end),
                  let nextDay = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: start) else { return }
            end = nextDay
        }
    }
}

private extension CalendarColor {
    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }

    var localizedName: String {
        switch self {
        case .red: "Rojo"
        case .orange: "Naranja"
        case .yellow: "Amarillo"
        case .green: "Verde"
        case .blue: "Azul"
        case .purple: "Morado"
        case .gray: "Gris"
        }
    }
}
