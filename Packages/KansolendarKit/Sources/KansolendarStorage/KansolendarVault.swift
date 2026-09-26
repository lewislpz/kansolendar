import Foundation
import KansolendarCore

public enum VaultState: Sendable, Equatable {
    case notCreated
    case locked
    case unlocking
    case unlocked
    case recoveryRequired
    case corrupt
}

public enum VaultError: Error, Sendable, Equatable {
    case vaultNotCreated
    case vaultAlreadyCreated
    case locked
    case recoveryRequired
    case authenticationCancelled
    case authenticationFailed
    case keychainUnavailable
    case corruptVault
    case unsupportedFormat
    case storageUnavailable
    case conflict
    case duplicateUID
    case timeZoneRulesChanged
    case unlockInProgress
    case invalidInput
    case queryLimitExceeded
}

/// Public app-facing boundary for the local encrypted vault. It exposes domain values
/// and safe error categories, never database handles, Keychain attributes, or keys.
public actor KansolendarVault {
    private let storage: SQLiteVaultDatabase

    public init() throws {
        do {
            let url = try VaultDatabaseLocation.applicationSupportURL()
            storage = try SQLiteVaultDatabase(path: url.path)
        } catch {
            throw Self.map(error)
        }
    }

    internal init(storage: SQLiteVaultDatabase) {
        self.storage = storage
    }

    public func state() async throws -> VaultState {
        do {
            try await storage.migrate()
            return Self.map(await storage.vaultState())
        } catch {
            throw Self.map(error)
        }
    }

    @discardableResult
    public func createVault() async throws -> UUID {
        do {
            return try await storage.createVault()
        } catch {
            throw Self.map(error)
        }
    }

    public func unlock() async throws {
        do {
            try await storage.unlockVault()
        } catch {
            throw Self.map(error)
        }
    }

    public func lock() async {
        await storage.lockVault()
    }

    public func save(_ calendar: LocalCalendar) async throws {
        do {
            try await storage.saveCalendar(calendar)
        } catch {
            throw Self.map(error)
        }
    }

    public func save(
        _ event: Event,
        recurrence: RecurrenceRule? = nil,
        cancellations: Set<EventOccurrenceKey> = []
    ) async throws {
        do {
            try await storage.saveEvent(event, recurrence: recurrence, cancellations: cancellations)
        } catch {
            throw Self.map(error)
        }
    }

    public func calendars() async throws -> [LocalCalendar] {
        do {
            return try await storage.calendars()
        } catch {
            throw Self.map(error)
        }
    }

    public func events() async throws -> [VaultEvent] {
        do {
            return try await storage.events()
        } catch {
            throw Self.map(error)
        }
    }

    /// Searches decrypted titles in the current session and expands recurrence only within Core's bounded query budget.
    public func events(matching query: EventSearchQuery) async throws -> [VaultEvent] {
        do {
            return try await storage.events(matching: query)
        } catch {
            throw Self.map(error)
        }
    }

    public func deleteEvent(id: UUID) async throws {
        do {
            try await storage.removeEvent(id: id)
        } catch {
            throw Self.map(error)
        }
    }

    public func deleteCalendar(id: UUID) async throws {
        do {
            try await storage.removeCalendar(id: id)
        } catch {
            throw Self.map(error)
        }
    }

    public func exportCalendar(id: UUID, to url: URL) async throws {
        do {
            let selected = try await storage.events().filter { $0.event.calendarID == id }
            guard selected.allSatisfy({ $0.recurrence == nil && $0.cancellations.isEmpty }) else {
                throw ICalendarCodecError.unsupported
            }
            try PrivateFileWriter.write(try ICalendarCodec.encode(events: selected.map(\.event)), to: url.path)
        } catch {
            throw Self.map(error)
        }
    }

    @discardableResult
    public func importCalendarEvents(from url: URL, into calendarID: UUID) async throws -> Int {
        do {
            let data = try PrivateFileReader.read(url.path, maximumBytes: ICalendarCodec.maximumBytes)
            let imported = try ICalendarCodec.decode(data, calendarID: calendarID)
            try await storage.importEvents(imported, into: calendarID)
            return imported.count
        } catch {
            throw Self.map(error)
        }
    }

    public func createBackup(at url: URL) async throws {
        do {
            try await storage.createSnapshot(at: url.path)
        } catch {
            throw Self.map(error)
        }
    }

    public func restoreBackup(at backupURL: URL, recoveryKitURL: URL) async throws {
        do {
            let kitData = try PrivateFileReader.read(
                recoveryKitURL.path,
                maximumBytes: RecoveryKit.maximumEncodedSize
            )
            try await storage.restoreBackup(from: backupURL.path, recoveryKitData: kitData)
        } catch {
            throw Self.map(error)
        }
    }

    /// Re-authenticates through Keychain and writes the recovery secret directly to a new file.
    /// The app layer selects the destination but never receives the raw key bytes.
    public func exportRecoveryKit(at url: URL) async throws {
        do {
            try await storage.exportRecoveryKit(to: url.path)
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ state: VaultAccessState) -> VaultState {
        switch state {
        case .notCreated: .notCreated
        case .locked: .locked
        case .unlocking: .unlocking
        case .unlocked: .unlocked
        case .recoveryRequired: .recoveryRequired
        case .corrupt: .corrupt
        }
    }

    private static func map(_ error: Error) -> VaultError {
        switch error {
        case VaultStorageError.vaultNotCreated:
            .vaultNotCreated
        case VaultStorageError.vaultAlreadyCreated:
            .vaultAlreadyCreated
        case VaultStorageError.locked, VaultKeySessionError.locked, VaultKeySessionError.staleGeneration:
            .locked
        case VaultStorageError.recoveryRequired, VaultKeyStoreError.missingKey:
            .recoveryRequired
        case VaultKeyStoreError.userCancelled:
            .authenticationCancelled
        case VaultKeyStoreError.accessDenied:
            .authenticationFailed
        case VaultKeyStoreError.missingEntitlement,
             VaultKeyStoreError.interactionNotAllowed,
             VaultKeyStoreError.keychainFailure,
             VaultKeyStoreError.accessControlCreationFailed:
            .keychainUnavailable
        case VaultKeyStoreError.invalidKeyMaterial:
            .corruptVault
        case VaultKeyStoreError.keyAlreadyExists, SQLiteVaultError.missingRecord:
            .conflict
        case VaultStorageError.corruptVault,
             SQLiteVaultError.integrityFailure,
             SQLiteVaultError.schemaMismatch,
             SQLiteVaultError.invalidIdentifier,
             SQLiteVaultError.invalidEnvelope,
             PayloadEnvelopeError.malformed,
             PayloadEnvelopeError.authenticationFailed,
             PayloadEnvelopeError.payloadTooLarge:
            .corruptVault
        case SQLiteVaultError.unsupportedSchemaVersion,
             PayloadEnvelopeError.unsupportedVersion,
             VaultPayloadCodecError.unsupportedVersion:
            .unsupportedFormat
        case SQLiteVaultError.constraintViolation:
            .conflict
        case SQLiteVaultError.snapshotDestinationExists,
             SQLiteVaultError.unsafeSnapshotDestination,
             RecoveryKitError.destinationExists:
            .conflict
        case SQLiteVaultError.restoreFailed,
             RecoveryKitError.malformed,
             RecoveryKitError.unsupportedVersion,
             RecoveryKitError.invalidKeyMaterial,
             RecoveryKitError.vaultMismatch:
            .corruptVault
        case VaultStorageError.duplicateUID:
            .duplicateUID
        case VaultStorageError.timeZoneRulesChanged, VaultPayloadCodecError.timeZoneRulesChanged:
            .timeZoneRulesChanged
        case VaultStorageError.unlockInProgress, VaultStorageError.unlockSuperseded:
            .unlockInProgress
        case DomainValidationError.queryLimitExceeded,
             DomainValidationError.candidateLimitExceeded,
             DomainValidationError.occurrenceLimitExceeded:
            .queryLimitExceeded
        case is DomainValidationError, VaultPayloadCodecError.invalidPayload:
            .invalidInput
        case ICalendarCodecError.malformed,
             ICalendarCodecError.unsupported,
             ICalendarCodecError.limitExceeded:
            .invalidInput
        case PrivateFileError.destinationExists:
            .conflict
        case is PrivateFileError:
            .storageUnavailable
        default:
            .storageUnavailable
        }
    }
}
