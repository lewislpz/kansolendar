import AppKit
import KansolendarCore
import KansolendarStorage
import SwiftUI

struct CalendarWorkspaceView: View {
    @Bindable var model: VaultViewModel
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
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

                Menu("Apariencia", systemImage: selectedAppearance.systemImage) {
                    Picker("Apariencia", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Label(option.localizedName, systemImage: option.systemImage)
                                .tag(option.rawValue)
                        }
                    }
                }
                .accessibilityLabel("Cambiar apariencia")
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

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }
}

private struct CalendarEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: VaultViewModel
    @State private var name = ""
    @State private var color: CalendarColor = .blue
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(
                title: "Nuevo calendario",
                subtitle: "Organiza tus eventos en un espacio privado y reconocible.",
                systemImage: "calendar.badge.plus",
                tint: color.swiftUIColor
            )

            Divider()

            VStack(spacing: 16) {
                EditorSection(title: "Identidad", systemImage: "textformat") {
                    EditorField("Nombre", hint: "Por ejemplo: Personal, Trabajo o Viajes") {
                        TextField("Nombre del calendario", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                EditorSection(title: "Color", systemImage: "paintpalette") {
                    Picker("Color del calendario", selection: $color) {
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

                    HStack(spacing: 12) {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calendarPreviewName)
                                .font(.headline)
                            Text("Vista previa en la barra lateral")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(22)

            Divider()

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
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var calendarPreviewName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Nombre del calendario" : trimmed
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
        VStack(spacing: 0) {
            EditorSheetHeader(
                title: event == nil ? "Nuevo evento" : "Editar evento",
                subtitle: event == nil ? "Añade una cita a tu calendario privado." : "Actualiza los detalles de esta cita.",
                systemImage: event == nil ? "calendar.badge.plus" : "calendar.badge.clock",
                tint: selectedCalendar?.color.swiftUIColor ?? .cyan
            )

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    EditorSection(title: "Detalles", systemImage: "text.alignleft") {
                        EditorField("Título", hint: "Describe el evento de forma breve") {
                            TextField("Título del evento", text: $title)
                                .textFieldStyle(.roundedBorder)
                        }

                        EditorField("Calendario") {
                            Picker("Calendario", selection: $calendarID) {
                                ForEach(model.calendars) { calendar in
                                    Label {
                                        Text(calendar.name)
                                    } icon: {
                                        calendar.color.swatchImage
                                            .accessibilityHidden(true)
                                    }
                                    .tag(calendar.id)
                                }
                            }
                            .labelsHidden()
                            .disabled(event != nil)
                        }
                    }

                    EditorSection(title: "Horario", systemImage: "clock") {
                        Toggle("Evento de todo el día", isOn: $isAllDay)

                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                            GridRow {
                                Text("Inicio")
                                    .foregroundStyle(.secondary)
                                DatePicker(
                                    "Inicio",
                                    selection: $start,
                                    displayedComponents: isAllDay ? .date : [.date, .hourAndMinute]
                                )
                                .labelsHidden()
                            }
                            GridRow {
                                Text("Fin")
                                    .foregroundStyle(.secondary)
                                DatePicker(
                                    "Fin",
                                    selection: $end,
                                    in: start...,
                                    displayedComponents: isAllDay ? .date : [.date, .hourAndMinute]
                                )
                                .labelsHidden()
                            }
                        }
                    }

                    EditorSection(title: "Información opcional", systemImage: "info.circle") {
                        EditorField("Ubicación") {
                            TextField("Añadir ubicación", text: $location)
                                .textFieldStyle(.roundedBorder)
                        }
                        EditorField("Notas") {
                            TextField("Añadir notas", text: $notes, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(3...6)
                        }
                    }
                }
                .padding(22)
            }

            Divider()

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
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 560, height: 620)
        .onChange(of: isAllDay) { _, enabled in
            guard enabled, Calendar.autoupdatingCurrent.isDate(start, inSameDayAs: end),
                  let nextDay = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: start) else { return }
            end = nextDay
        }
    }

    private var selectedCalendar: LocalCalendar? {
        model.calendars.first { $0.id == calendarID }
    }
}

private struct EditorSheetHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }
}

private struct EditorSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }
}

private struct EditorField<Content: View>: View {
    let label: String
    let hint: String?
    @ViewBuilder let content: Content

    init(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
            content
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
