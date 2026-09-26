import KansolendarCore
import KansolendarStorage
import SwiftUI

struct RootView: View {
    @Environment(\.appAccentColor) private var appAccentColor
    @State private var model = VaultViewModel()

    var body: some View {
        Group {
            if model.vaultState == .unlocked {
                CalendarWorkspaceView(model: model)
            } else {
                vaultGate
            }
        }
        .frame(minWidth: 1_100, minHeight: 700)
        .task { await model.start() }
    }

    private var vaultGate: some View {
        VStack(spacing: 18) {
            Image("KansolendarLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(appAccentColor.opacity(0.35), lineWidth: 1)
                }
                .accessibilityHidden(true)

            Text(KansolendarBuildInfo.productName)
                .font(.largeTitle.monospaced().weight(.semibold))
                .tracking(1.2)

            Text("LOCAL / ENCRYPTED / OFFLINE")
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)

            statePanel
                .padding(.top, 8)

            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(appAccentColor.opacity(0.07), in: Capsule())
                    .accessibilityIdentifier("vault-message")
            }

            Text("Your calendar stays on this Mac. No accounts. No servers. No sync.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(minWidth: 520, minHeight: 360)
        .padding(32)
        .background(appAccentColor.opacity(0.025))
    }

    @ViewBuilder
    private var statePanel: some View {
        if model.isBusy {
            ProgressView("Preparing encrypted storage…")
                .controlSize(.small)
        } else {
            switch model.vaultState {
            case .notCreated:
                Button("Create Private Vault", systemImage: "lock.shield") {
                    model.createVault()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("create-vault")
                Text("The key is generated on this Mac. No account required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .locked:
                Button("Retry Unlock", systemImage: "touchid") {
                    model.unlock()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("unlock-vault")
                Text("Touch ID or your Mac password unlocks the local key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unlocked:
                Label("Private vault unlocked", systemImage: "lock.open.fill")
                    .font(.headline)
                    .foregroundStyle(appAccentColor)
                Text("Calendar data is available for this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Lock Now", systemImage: "lock") {
                    model.lock()
                }
                .accessibilityIdentifier("lock-vault")
            case .unlocking:
                ProgressView("Waiting for macOS authentication…")
                    .controlSize(.small)
            case .recoveryRequired:
                Label("Key recovery required", systemImage: "exclamationmark.lock")
                    .font(.headline)
                Text("Choose an encrypted backup and its matching recovery kit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Restore Backup…", systemImage: "externaldrive.badge.timemachine") {
                    chooseAndRestoreBackup()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            case .corrupt:
                Label("The vault cannot be opened", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Your data will be preserved without being overwritten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case nil:
                Label("Local vault unavailable", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.headline)
            }
        }
    }

    private func chooseAndRestoreBackup() {
        guard let backup = ExportPanel.chooseBackupForRestore(),
              let kit = ExportPanel.chooseRecoveryKitForRestore() else { return }
        Task { await model.restoreBackup(at: backup, recoveryKitURL: kit) }
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
    private(set) var isExporting = false
    var message: String?
    private var hasAttemptedAutomaticUnlock = false

    init() {
        do {
            vault = try KansolendarVault()
        } catch {
            vault = nil
            message = "Local storage could not be prepared. No personal information was saved."
        }
    }

    func start() async {
        await refresh()
        guard vaultState == .locked, !hasAttemptedAutomaticUnlock else { return }
        hasAttemptedAutomaticUnlock = true
        unlock()
    }

    func refresh() async {
        guard let vault else { return }
        do {
            vaultState = try await vault.state()
        } catch let error as VaultError {
            message = Self.message(for: error)
        } catch {
            message = "The local vault state could not be read."
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
                message = "The private vault could not be created. No personal information was saved."
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
                message = "The local vault could not be unlocked."
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
            message = "The local calendar could not be loaded."
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
            message = "The calendar name is not valid."
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
            message = "Check the event title and time range."
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
            message = "The event could not be deleted."
        }
        return false
    }

    func moveEvent(id: UUID, to date: CivilDate) async -> Bool {
        guard let vault, let stored = events.first(where: { $0.event.id == id }) else { return false }
        guard stored.recurrence == nil else {
            message = "Recurring series must be moved from their editor to avoid ambiguous changes."
            return false
        }
        do {
            var event = stored.event
            try event.update(
                title: event.title,
                notes: event.notes,
                location: event.location,
                time: event.time.moved(to: date)
            )
            try await vault.save(event)
            await loadContent()
            return true
        } catch let error as VaultError {
            handleContentError(error)
        } catch {
            message = "The event could not be moved to that day. Check the time-zone transition."
        }
        return false
    }

    func deleteCalendar(id: UUID) async -> Bool {
        guard let vault else { return false }
        do {
            try await vault.deleteCalendar(id: id)
            await loadContent()
            return true
        } catch let error as VaultError {
            handleContentError(error)
        } catch {
            message = "The calendar could not be deleted."
        }
        return false
    }

    func createBackup(at url: URL) async {
        guard let vault else { return }
        isExporting = true
        defer { isExporting = false }
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            try await vault.createBackup(at: url)
            message = "Encrypted backup saved. Keep the recovery kit separately."
        } catch let error as VaultError {
            message = error == .conflict
                ? "That file already exists. Choose a new name to preserve the previous backup."
                : Self.message(for: error)
        } catch {
            message = "The encrypted backup could not be created."
        }
    }

    func exportRecoveryKit(at url: URL) async {
        guard let vault else { return }
        isExporting = true
        defer { isExporting = false }
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            try await vault.exportRecoveryKit(at: url)
            message = "Recovery kit saved. Do not store it with the backup."
        } catch let error as VaultError {
            message = error == .conflict
                ? "That file already exists. Choose a new name instead of overwriting it."
                : Self.message(for: error)
        } catch {
            message = "The recovery kit could not be exported."
        }
    }

    func restoreBackup(at backupURL: URL, recoveryKitURL: URL) async {
        guard let vault else { return }
        isExporting = true
        defer { isExporting = false }
        let backupAccess = backupURL.startAccessingSecurityScopedResource()
        let kitAccess = recoveryKitURL.startAccessingSecurityScopedResource()
        defer {
            if backupAccess { backupURL.stopAccessingSecurityScopedResource() }
            if kitAccess { recoveryKitURL.stopAccessingSecurityScopedResource() }
        }
        do {
            try await vault.restoreBackup(at: backupURL, recoveryKitURL: recoveryKitURL)
            vaultState = try await vault.state()
            await loadContent()
            message = "Encrypted backup restored and verified."
        } catch let error as VaultError {
            message = error == .corruptVault
                ? "The backup or recovery kit is invalid or does not match. Your current vault was preserved."
                : Self.message(for: error)
        } catch {
            message = "The backup could not be restored. Your current vault was preserved."
        }
    }

    func exportCalendar(id: UUID, to url: URL) async {
        guard let vault else { return }
        isExporting = true
        defer { isExporting = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try await vault.exportCalendar(id: id, to: url)
            message = "Calendar exported as an unencrypted iCalendar file."
        } catch let error as VaultError {
            message = error == .conflict ? "That file already exists. Choose a new name." : Self.message(for: error)
        } catch {
            message = "The calendar could not be exported."
        }
    }

    func importCalendarEvents(from url: URL, into calendarID: UUID) async {
        guard let vault else { return }
        isExporting = true
        defer { isExporting = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let count = try await vault.importCalendarEvents(from: url, into: calendarID)
            await loadContent()
            message = "Imported \(count) \(count == 1 ? "event" : "events") safely."
        } catch let error as VaultError {
            message = error == .duplicateUID
                ? "Import cancelled because an event UID already exists. No events were added."
                : "This iCalendar file contains invalid or unsupported data. No events were added."
        } catch {
            message = "The calendar could not be imported. No events were added."
        }
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
        let foundationZone = TimeZone.autoupdatingCurrent
        let zoneID = try TimeZoneID(
            TimeZone.knownTimeZoneIdentifiers.contains(foundationZone.identifier)
                ? foundationZone.identifier
                : "UTC"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = foundationZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute else {
            throw DomainValidationError.invalidCivilDate
        }
        let duration = Int64(end.timeIntervalSince(start).rounded(.towardZero))
        let localStart = try LocalDateTime(
            date: CivilDate(year: year, month: month, day: day),
            hour: hour,
            minute: minute,
            second: parts.second ?? 0
        )
        return .zoned(try ZonedEventTime(
            localStart: localStart,
            timeZone: zoneID,
            repeatedTime: .first,
            durationSeconds: duration,
            resolver: FoundationLocalTimeResolver()
        ))
    }

    private static func optionalText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func message(for error: VaultError) -> String {
        switch error {
        case .authenticationCancelled:
            "Authentication cancelled. The calendar remains locked."
        case .authenticationFailed:
            "macOS denied access. The calendar remains locked."
        case .keychainUnavailable:
            "macOS could not access secure storage. The calendar was not unlocked."
        case .recoveryRequired:
            "The original key is missing. A replacement will not be generated automatically."
        case .corruptVault:
            "The vault failed its integrity check; its files will be preserved."
        case .unsupportedFormat:
            "This vault uses a format that this version cannot open."
        case .vaultAlreadyCreated:
            "A private calendar already exists on this Mac."
        case .vaultNotCreated:
            "A private calendar has not been created yet."
        case .locked:
            "The calendar is locked."
        case .conflict, .duplicateUID:
            "The operation conflicts with existing data."
        case .timeZoneRulesChanged:
            "System time-zone rules changed; review saved times before editing them."
        case .unlockInProgress:
            "An authentication request is already in progress."
        case .invalidInput:
            "The operation data is invalid. The calendar was not changed."
        case .queryLimitExceeded:
            "The search is too broad. Narrow the range and try again."
        case .storageUnavailable:
            "The local vault is unavailable. No partial information was shown."
        }
    }
}
