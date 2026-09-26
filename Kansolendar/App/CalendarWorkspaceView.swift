import AppKit
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
    @State private var calendarPendingDeletion: LocalCalendar?
    @State private var searchText = ""
    @State private var isConfirmingRecoveryExport = false
    @State private var selectedDate = CivilDate.localToday
    @State private var displayedMonth = CalendarMonth(containing: CivilDate.localToday)

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
                        .contextMenu {
                            Button("Eliminar calendario", role: .destructive) {
                                calendarPendingDeletion = calendar
                            }
                        }
                    }
                }
            }
            .navigationTitle("Kansolendar")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 14) {
                    Button("Nuevo calendario", systemImage: "plus") {
                        isPresentingCalendarEditor = true
                    }
                    .buttonStyle(.plain)
                    if let selectedCalendarID,
                       let calendar = model.calendars.first(where: { $0.id == selectedCalendarID }) {
                        Button("Eliminar calendario", systemImage: "trash", role: .destructive) {
                            calendarPendingDeletion = calendar
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 210)
        } detail: {
            calendarSurface
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

                Menu("Exportar", systemImage: "square.and.arrow.up") {
                    Button("Backup cifrado…", systemImage: "externaldrive") {
                        guard let url = ExportPanel.chooseBackupDestination() else { return }
                        Task { await model.createBackup(at: url) }
                    }
                    Button("Kit de recuperación…", systemImage: "key") {
                        isConfirmingRecoveryExport = true
                    }
                }
                .disabled(model.isExporting)
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
                preferredCalendarID: selectedCalendarID,
                preferredDate: selectedDate
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
        .alert("¿Eliminar este calendario?", isPresented: calendarDeletionAlertBinding, presenting: calendarPendingDeletion) { calendar in
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar calendario", role: .destructive) {
                Task {
                    if await model.deleteCalendar(id: calendar.id), selectedCalendarID == calendar.id {
                        selectedCalendarID = nil
                    }
                }
            }
        } message: { calendar in
            let count = model.events.filter { $0.event.calendarID == calendar.id }.count
            Text("“\(calendar.name)” y sus \(count) \(count == 1 ? "evento" : "eventos") se eliminarán de forma permanente.")
        }
        .confirmationDialog(
            "El kit permite descifrar cualquier copia de esta bóveda",
            isPresented: $isConfirmingRecoveryExport,
            titleVisibility: .visible
        ) {
            Button("Elegir ubicación…") {
                guard let url = ExportPanel.chooseRecoveryKitDestination() else { return }
                Task { await model.exportRecoveryKit(at: url) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Guárdalo separado del backup. Cualquier persona con ambos archivos podrá leer el calendario.")
        }
    }

    @ViewBuilder
    private var calendarSurface: some View {
        if model.isLoadingContent {
            ProgressView("Cargando calendario privado…")
        } else {
            MonthCalendarView(
                events: visibleEvents,
                calendars: model.calendars,
                displayedMonth: $displayedMonth,
                selectedDate: $selectedDate,
                canCreateEvent: !model.calendars.isEmpty,
                onCreateEvent: { date in
                    selectedDate = date
                    editorEvent = nil
                    isPresentingEventEditor = true
                },
                onEditEvent: { event in
                    editorEvent = event
                    isPresentingEventEditor = true
                },
                onDeleteEvent: { eventPendingDeletion = $0 },
                onMoveEvent: { eventID, date in
                    Task {
                        if await model.moveEvent(id: eventID, to: date) {
                            selectedDate = date
                            displayedMonth = CalendarMonth(containing: date)
                        }
                    }
                }
            )
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
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { eventPendingDeletion != nil },
            set: { if !$0 { eventPendingDeletion = nil } }
        )
    }

    private var calendarDeletionAlertBinding: Binding<Bool> {
        Binding(
            get: { calendarPendingDeletion != nil },
            set: { if !$0 { calendarPendingDeletion = nil } }
        )
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
                    Label {
                        Text(option.localizedName)
                    } icon: {
                        option.swatchImage
                            .accessibilityHidden(true)
                    }
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

    init(model: VaultViewModel, event: Event?, preferredCalendarID: UUID?, preferredDate: CivilDate) {
        self.model = model
        self.event = event
        let initialCalendarID = event?.calendarID ?? preferredCalendarID ?? model.calendars.first?.id ?? UUID()
        _calendarID = State(initialValue: initialCalendarID)
        _title = State(initialValue: event?.title ?? "")
        _notes = State(initialValue: event?.notes ?? "")
        _location = State(initialValue: event?.location ?? "")
        let preferredStart = Calendar.autoupdatingCurrent.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: MonthCalendarView.foundationDate(preferredDate)
        ) ?? Date()
        let initialStart = event.map(VaultViewModel.startDate(for:)) ?? preferredStart
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

extension CalendarColor {
    var swatchImage: Image {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image).renderingMode(.original)
    }

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

    private var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
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
