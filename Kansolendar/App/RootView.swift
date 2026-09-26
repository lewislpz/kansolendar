import KansolendarCore
import KansolendarStorage
import SwiftUI

struct RootView: View {
    @State private var model = VaultViewModel()

    var body: some View {
        Group {
            if model.vaultState == .unlocked {
                CalendarWorkspaceView(model: model)
            } else {
                vaultGate
            }
        }
        .task { await model.refresh() }
    }

    private var vaultGate: some View {
        VStack(spacing: 18) {
            Image(systemName: "calendar.badge.lock")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)

            Text(KansolendarBuildInfo.productName)
                .font(.largeTitle.weight(.semibold))

            Text("Tu calendario permanece en este Mac.")
                .foregroundStyle(.secondary)

            statePanel
                .padding(.top, 8)

            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .accessibilityIdentifier("vault-message")
            }

            Text("Sin cuentas, servidores ni sincronización.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(minWidth: 520, minHeight: 360)
        .padding(32)
    }

    @ViewBuilder
    private var statePanel: some View {
        if model.isBusy {
            ProgressView("Preparando el almacén privado…")
                .controlSize(.small)
        } else {
            switch model.vaultState {
            case .notCreated:
                Button("Crear calendario privado", systemImage: "lock.shield") {
                    model.createVault()
                }
                .controlSize(.large)
                .accessibilityIdentifier("create-vault")
                Text("La clave se genera en este Mac. No necesitas crear una cuenta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .locked:
                Button("Desbloquear calendario", systemImage: "lock.open") {
                    model.unlock()
                }
                .controlSize(.large)
                .accessibilityIdentifier("unlock-vault")
                Text("macOS solicitará autenticación para usar la clave local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unlocked:
                Label("Almacén privado desbloqueado", systemImage: "lock.open.fill")
                    .font(.headline)
                Text("La agenda todavía está en construcción.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Bloquear ahora", systemImage: "lock") {
                    model.lock()
                }
                .accessibilityIdentifier("lock-vault")
            case .unlocking:
                ProgressView("Esperando autenticación de macOS…")
                    .controlSize(.small)
            case .recoveryRequired:
                Label("Se necesita recuperar la clave", systemImage: "exclamationmark.lock")
                    .font(.headline)
                Text("No se ha creado una clave de reemplazo. La recuperación aún no está disponible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .corrupt:
                Label("No se puede abrir el almacén", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Los datos se conservarán sin sobrescribirlos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case nil:
                Label("Almacén local no disponible", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.headline)
            }
        }
    }
}

@MainActor
@Observable
final class VaultViewModel {
    private let vault: KansolendarVault?
    private(set) var vaultState: VaultState?
    private(set) var isBusy = false
    private(set) var calendars: [LocalCalendar] = []
    private(set) var events: [VaultEvent] = []
    private(set) var isLoadingContent = false
    var message: String?

    init() {
        do {
            vault = try KansolendarVault()
        } catch {
            vault = nil
            message = "No se pudo preparar el almacén local. No se ha guardado información personal."
        }
    }

    func refresh() async {
        guard let vault else { return }
        do {
            vaultState = try await vault.state()
        } catch let error as VaultError {
            message = Self.message(for: error)
        } catch {
            message = "No se pudo consultar el estado del almacén local."
        }
    }

    func createVault() {
        guard let vault else { return }
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            do {
                _ = try await vault.createVault()
                vaultState = try await vault.state()
                await loadContent()
            } catch let error as VaultError {
                message = Self.message(for: error)
                await refresh()
            } catch {
                message = "No se pudo crear el almacén privado. No se ha guardado información personal."
                await refresh()
            }
        }
    }

    func unlock() {
        guard let vault else { return }
        isBusy = true
        message = nil
        vaultState = .unlocking
        Task {
            defer { isBusy = false }
            do {
                try await vault.unlock()
                vaultState = try await vault.state()
                await loadContent()
            } catch let error as VaultError {
                message = Self.message(for: error)
                await refresh()
            } catch {
                message = "No se pudo desbloquear el almacén local."
                await refresh()
            }
        }
    }

    func lock() {
        guard let vault else { return }
        clearPrivateContent()
        vaultState = .locked
        Task {
            await vault.lock()
        }
    }

    func loadContent() async {
        guard let vault, vaultState == .unlocked else {
            clearPrivateContent()
            return
        }
        isLoadingContent = true
        defer { isLoadingContent = false }
        do {
            async let storedCalendars = vault.calendars()
            async let storedEvents = vault.events()
            calendars = try await storedCalendars.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            events = try await storedEvents.sorted { Self.startDate(for: $0.event) < Self.startDate(for: $1.event) }
            message = nil
        } catch let error as VaultError {
            handleContentError(error)
        } catch {
            message = "No se pudo cargar el calendario local."
        }
    }

    func createCalendar(name: String, color: CalendarColor) async -> Bool {
        guard let vault else { return false }
        do {
            let identifier = TimeZone.autoupdatingCurrent.identifier
            let timeZone = try TimeZoneID(TimeZone.knownTimeZoneIdentifiers.contains(identifier) ? identifier : "UTC")
            let calendar = try LocalCalendar(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                color: color,
                sortOrder: calendars.count,
                defaultTimeZone: timeZone
            )
            try await vault.save(calendar)
            await loadContent()
            return true
        } catch let error as VaultError {
            handleContentError(error)
        } catch {
            message = "El nombre del calendario no es válido."
        }
        return false
    }

    func saveEvent(
        existing: Event?,
        calendarID: UUID,
        title: String,
        notes: String?,
        location: String?,
        start: Date,
        end: Date,
        isAllDay: Bool
    ) async -> Bool {
        guard let vault else { return false }
        do {
            let eventTime = try Self.eventTime(start: start, end: end, isAllDay: isAllDay)
            let normalizedNotes = Self.optionalText(notes)
            let normalizedLocation = Self.optionalText(location)
            let event: Event
            if var existing {
                try existing.update(
                    title: title,
                    notes: normalizedNotes,
                    location: normalizedLocation,
                    time: eventTime
                )
                event = existing
            } else {
                event = try Event(
                    calendarID: calendarID,
                    title: title,
                    notes: normalizedNotes,
                    location: normalizedLocation,
                    time: eventTime
                )
            }
            try await vault.save(event)
            await loadContent()
            return true
        } catch let error as VaultError {
            handleContentError(error)
        } catch {
            message = "Revisa el título y el intervalo del evento."
        }
        return false
    }

    func deleteEvent(id: UUID) async -> Bool {
        guard let vault else { return false }
        do {
            try await vault.deleteEvent(id: id)
            await loadContent()
            return true
        } catch let error as VaultError {
            handleContentError(error)
        } catch {
            message = "No se pudo eliminar el evento."
        }
        return false
    }

    private func clearPrivateContent() {
        calendars = []
        events = []
    }

    private func handleContentError(_ error: VaultError) {
        message = Self.message(for: error)
        if error == .locked || error == .authenticationCancelled || error == .authenticationFailed {
            clearPrivateContent()
            vaultState = .locked
        }
    }

    static func startDate(for event: Event) -> Date {
        switch event.time {
        case let .allDay(value):
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.year = value.range.start.year
            components.month = value.range.start.month
            components.day = value.range.start.day
            return components.date ?? .distantPast
        case let .utc(value):
            return Date(timeIntervalSince1970: TimeInterval(value.start.unixSeconds))
        case let .zoned(value):
            return Date(timeIntervalSince1970: TimeInterval(value.resolvedStart.unixSeconds))
        }
    }

    static func endDate(for event: Event) -> Date {
        switch event.time {
        case let .allDay(value):
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.year = value.range.endExclusive.year
            components.month = value.range.endExclusive.month
            components.day = value.range.endExclusive.day
            return components.date ?? startDate(for: event)
        case let .utc(value):
            return Date(timeIntervalSince1970: TimeInterval(value.endExclusive.unixSeconds))
        case let .zoned(value):
            return Date(timeIntervalSince1970: TimeInterval(value.endExclusive.unixSeconds))
        }
    }

    static func isAllDay(_ event: Event) -> Bool {
        if case .allDay = event.time { return true }
        return false
    }

    private static func eventTime(start: Date, end: Date, isAllDay: Bool) throws -> EventTime {
        guard end > start else { throw DomainValidationError.invalidRange }
        if isAllDay {
            let calendar = Calendar.autoupdatingCurrent
            let startParts = calendar.dateComponents([.year, .month, .day], from: start)
            let endParts = calendar.dateComponents([.year, .month, .day], from: end)
            guard let startYear = startParts.year, let startMonth = startParts.month, let startDay = startParts.day,
                  let endYear = endParts.year, let endMonth = endParts.month, let endDay = endParts.day else {
                throw DomainValidationError.invalidCivilDate
            }
            return .allDay(try AllDayEventTime(
                start: CivilDate(year: startYear, month: startMonth, day: startDay),
                endExclusive: CivilDate(year: endYear, month: endMonth, day: endDay)
            ))
        }
        let startSeconds = Int64(start.timeIntervalSince1970.rounded(.towardZero))
        let duration = Int64(end.timeIntervalSince(start).rounded(.towardZero))
        return .utc(try TimedEventTime(start: Instant(unixSeconds: startSeconds), durationSeconds: duration))
    }

    private static func optionalText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func message(for error: VaultError) -> String {
        switch error {
        case .authenticationCancelled:
            "Autenticación cancelada. El calendario sigue bloqueado."
        case .authenticationFailed:
            "macOS no autorizó el acceso. El calendario sigue bloqueado."
        case .keychainUnavailable:
            "macOS no pudo acceder al almacén seguro. El calendario no se ha desbloqueado."
        case .recoveryRequired:
            "Falta la clave original. No se generará otra automáticamente."
        case .corruptVault:
            "El almacén no superó la comprobación de integridad; se conservarán sus archivos."
        case .unsupportedFormat:
            "Este almacén usa un formato que esta versión no puede abrir."
        case .vaultAlreadyCreated:
            "Ya existe un calendario privado en este Mac."
        case .vaultNotCreated:
            "Todavía no se ha creado un calendario privado."
        case .locked:
            "El calendario está bloqueado."
        case .conflict, .duplicateUID:
            "La operación entra en conflicto con datos existentes."
        case .timeZoneRulesChanged:
            "Las reglas horarias del sistema cambiaron; revisa las horas guardadas antes de editarlas."
        case .unlockInProgress:
            "Ya hay una solicitud de autenticación en curso."
        case .invalidInput:
            "Los datos de la operación no son válidos. No se ha modificado el calendario."
        case .queryLimitExceeded:
            "La búsqueda es demasiado amplia. Acota el intervalo y vuelve a intentarlo."
        case .storageUnavailable:
            "El almacén local no está disponible. No se ha mostrado información parcial."
        }
    }
}
