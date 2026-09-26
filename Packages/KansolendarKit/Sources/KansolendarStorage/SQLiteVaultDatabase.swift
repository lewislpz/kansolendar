import CSQLite
import CryptoKit
import Darwin
import Foundation
import KansolendarCore

internal enum SQLiteVaultError: Error, Equatable, Sendable {
    case openFailed(Int32)
    case filesystemFailure(Int32)
    case unsafeDatabaseFile
    case databaseFailure(Int32)
    case unsupportedSchemaVersion(Int32)
    case schemaMismatch
    case invalidIdentifier
    case invalidEnvelope
    case constraintViolation
    case missingRecord
    case integrityFailure
    case foreignKeyFailure
    case snapshotDestinationExists
    case unsafeSnapshotDestination
    case restoreFailed
}

internal enum VaultAccessState: Sendable, Equatable {
    case notCreated
    case locked
    case unlocking(UUID)
    case unlocked(UUID)
    case recoveryRequired
    case corrupt
}

internal enum VaultStorageError: Error, Equatable, Sendable {
    case vaultNotCreated
    case vaultAlreadyCreated
    case locked
    case recoveryRequired
    case corruptVault
    case unlockSuperseded
    case timeZoneRulesChanged
    case duplicateUID
    case unlockInProgress
}

internal enum VaultPayloadTable: Sendable {
    case calendar
    case event
    case eventException

    fileprivate var selectSQL: String {
        switch self {
        case .calendar: "SELECT payload_envelope FROM calendars WHERE id = ?1"
        case .event: "SELECT payload_envelope FROM events WHERE id = ?1"
        case .eventException: "SELECT payload_envelope FROM event_exceptions WHERE id = ?1"
        }
    }
}

internal struct VaultMetadata: Sendable, Equatable {
    let vaultID: UUID
    let activeKeyID: UUID
    let controlEnvelope: Data
}

private struct VaultControlPayload: Codable, Sendable {
    let version: Int
    let vaultID: UUID
    let keyID: UUID
}

internal struct VaultCalendarRecord: Sendable, Equatable {
    let id: UUID
    let envelope: Data
}

internal struct VaultEventRecord: Sendable, Equatable {
    let id: UUID
    let calendarID: UUID
    let envelope: Data
}

internal struct VaultExceptionRecord: Sendable, Equatable {
    let id: UUID
    let eventID: UUID
    let envelope: Data
}

/// Serializes access to one SQLite connection. Public-facing storage must pass only
/// UUID relationships and authenticated envelopes, never plaintext business values.
internal actor SQLiteVaultDatabase {
    static let schemaVersion: Int32 = 1
    static let minimumEnvelopeSize = 33
    static let maximumEnvelopeSize = 131_105

    private let connection: SQLiteConnection
    private let keyStore: any VaultKeyStore
    private var keySession = VaultKeySession()
    private var accessState: VaultAccessState = .locked
    private var activeKeyOperation: UUID?

    init(path: String, keyStore: any VaultKeyStore = KeychainVaultKeyStore()) throws {
        connection = try SQLiteConnection(path: path)
        self.keyStore = keyStore
        try connection.configure()
    }

    func vaultState() -> VaultAccessState {
        accessState
    }

    func createVault() async throws -> UUID {
        if case .unlocking = accessState { throw VaultStorageError.unlockInProgress }
        try migrate()
        guard try metadata() == nil else {
            accessState = .locked
            throw VaultStorageError.vaultAlreadyCreated
        }
        guard try !hasBusinessRecords() else {
            accessState = .corrupt
            throw VaultStorageError.corruptVault
        }

        let attempt = UUID()
        activeKeyOperation = attempt
        accessState = .unlocking(attempt)
        let vaultID = UUID()
        let keyID = UUID()
        do {
            let key = try await keyStore.create(vaultID: vaultID, keyID: keyID)
            guard activeKeyOperation == attempt else { throw VaultStorageError.unlockSuperseded }

            let generation = keySession.unlock(with: key)
            let control = VaultControlPayload(version: 1, vaultID: vaultID, keyID: keyID)
            let controlBytes = try JSONEncoder().encode(control)
            let context = PayloadContext(
                vaultID: vaultID,
                keyID: keyID,
                recordKind: .control,
                recordID: vaultID
            )
            let envelope = try keySession.seal(controlBytes, context: context, expectedGeneration: generation)
            try createVault(vaultID: vaultID, keyID: keyID, controlEnvelope: envelope)
            activeKeyOperation = nil
            accessState = .unlocked(generation)
            return vaultID
        } catch {
            _ = keySession.lock()
            if activeKeyOperation == attempt {
                activeKeyOperation = nil
                accessState = .notCreated
            }
            throw error
        }
    }

    func unlockVault() async throws {
        if case .unlocked = accessState { return }
        if case .unlocking = accessState { throw VaultStorageError.unlockInProgress }
        try migrate()
        guard let metadata = try metadata() else {
            if try hasBusinessRecords() {
                accessState = .corrupt
                throw VaultStorageError.corruptVault
            }
            accessState = .notCreated
            throw VaultStorageError.vaultNotCreated
        }

        let attempt = UUID()
        activeKeyOperation = attempt
        accessState = .unlocking(attempt)
        let key: SymmetricKey
        do {
            key = try await keyStore.load(vaultID: metadata.vaultID, keyID: metadata.activeKeyID)
        } catch let error as VaultKeyStoreError {
            guard activeKeyOperation == attempt else { throw VaultStorageError.unlockSuperseded }
            activeKeyOperation = nil
            accessState = error == .missingKey ? .recoveryRequired : .locked
            if error == .missingKey { throw VaultStorageError.recoveryRequired }
            throw error
        } catch {
            guard activeKeyOperation == attempt else { throw VaultStorageError.unlockSuperseded }
            activeKeyOperation = nil
            accessState = .locked
            throw error
        }
        guard activeKeyOperation == attempt else { throw VaultStorageError.unlockSuperseded }

        let generation = keySession.unlock(with: key)
        do {
            let context = PayloadContext(
                vaultID: metadata.vaultID,
                keyID: metadata.activeKeyID,
                recordKind: .control,
                recordID: metadata.vaultID
            )
            let bytes = try keySession.open(
                metadata.controlEnvelope,
                context: context,
                expectedGeneration: generation
            )
            let control = try JSONDecoder().decode(VaultControlPayload.self, from: bytes)
            guard control.version == 1,
                  control.vaultID == metadata.vaultID,
                  control.keyID == metadata.activeKeyID else {
                throw VaultStorageError.corruptVault
            }
            activeKeyOperation = nil
            accessState = .unlocked(generation)
        } catch {
            _ = keySession.lock()
            activeKeyOperation = nil
            accessState = .corrupt
            throw VaultStorageError.corruptVault
        }
    }

    func lockVault() {
        activeKeyOperation = nil
        _ = keySession.lock()
        switch accessState {
        case .notCreated:
            break
        default:
            accessState = .locked
        }
    }

    func createSnapshot(at path: String) async throws {
        _ = try unlockedGeneration()
        guard let metadata = try metadata() else { throw VaultStorageError.vaultNotCreated }
        let key = try await keyStore.load(vaultID: metadata.vaultID, keyID: metadata.activeKeyID)
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kansolendar-Backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagingURL = stagingDirectory.appendingPathComponent("verified.sqlite")
        try connection.snapshot(to: stagingURL.path)
        try await Self.validateBackup(
            at: stagingURL.path,
            key: key,
            expectedVaultID: metadata.vaultID,
            expectedKeyID: metadata.activeKeyID
        )
        do {
            try PrivateFileCopier.copyNewFile(from: stagingURL.path, to: path)
        } catch PrivateFileError.destinationExists {
            throw SQLiteVaultError.snapshotDestinationExists
        }
    }

    func restoreBackup(from sourcePath: String, recoveryKitData: Data) async throws {
        let kit = try RecoveryKit.decode(recoveryKitData)
        let replacementKey = try kit.makeKey()
        let staging = try Self.stageBackup(from: sourcePath)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

        try await Self.validateBackup(
            at: staging.path,
            key: replacementKey,
            expectedVaultID: kit.vaultID,
            expectedKeyID: kit.keyID
        )

        let previousAccessState = accessState
        let previousMetadata = try metadata()
        let previousKey: SymmetricKey?
        if let previousMetadata {
            do {
                previousKey = try await keyStore.load(
                    vaultID: previousMetadata.vaultID,
                    keyID: previousMetadata.activeKeyID
                )
            } catch VaultKeyStoreError.missingKey {
                previousKey = nil
            }
        } else {
            previousKey = nil
        }
        let safetyURL = staging.deletingLastPathComponent().appendingPathComponent("active-safety.sqlite")
        try connection.snapshot(to: safetyURL.path)

        let hasSameStoredKey = previousMetadata?.vaultID == kit.vaultID &&
            previousMetadata?.activeKeyID == kit.keyID && previousKey != nil
        var installedReplacement = false
        if !hasSameStoredKey {
            try await keyStore.install(replacementKey, vaultID: kit.vaultID, keyID: kit.keyID)
            installedReplacement = true
        }

        do {
            _ = keySession.lock()
            accessState = .locked
            try connection.replaceContents(from: staging.path)
            let generation = keySession.unlock(with: replacementKey)
            accessState = .unlocked(generation)
            _ = try calendars()
            _ = try events()
        } catch {
            try? connection.replaceContents(from: safetyURL.path)
            _ = keySession.lock()
            if let previousKey {
                let generation = keySession.unlock(with: previousKey)
                accessState = .unlocked(generation)
            } else {
                switch previousAccessState {
                case .recoveryRequired: accessState = .recoveryRequired
                case .corrupt: accessState = .corrupt
                case .notCreated: accessState = .notCreated
                default: accessState = .locked
                }
            }
            if installedReplacement {
                try? await keyStore.delete(vaultID: kit.vaultID, keyID: kit.keyID)
            }
            throw SQLiteVaultError.restoreFailed
        }

        if let previousMetadata,
           previousMetadata.vaultID != kit.vaultID || previousMetadata.activeKeyID != kit.keyID {
            try? await keyStore.delete(vaultID: previousMetadata.vaultID, keyID: previousMetadata.activeKeyID)
        }
    }

    private static func validateBackup(
        at path: String,
        key: SymmetricKey,
        expectedVaultID: UUID,
        expectedKeyID: UUID
    ) async throws {
        let validator = try SQLiteVaultDatabase(
            path: path,
            keyStore: FixedVaultKeyStore(
                vaultID: expectedVaultID,
                keyID: expectedKeyID,
                key: key
            )
        )
        try await validator.unlockVault()
        guard let metadata = try await validator.metadata(),
              metadata.vaultID == expectedVaultID,
              metadata.activeKeyID == expectedKeyID else {
            throw RecoveryKitError.vaultMismatch
        }
        _ = try await validator.calendars()
        _ = try await validator.events()
        await validator.lockVault()
    }

    private static func stageBackup(from sourcePath: String) throws -> URL {
        var info = stat()
        guard lstat(sourcePath, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_size > 0,
              info.st_size <= 1_073_741_824 else {
            throw SQLiteVaultError.unsafeSnapshotDestination
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kansolendar-Restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent("candidate.sqlite")
        do {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: destination.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func exportRecoveryKit(to path: String) async throws {
        let expectedGeneration = try unlockedGeneration()
        guard let metadata = try metadata() else { throw VaultStorageError.vaultNotCreated }
        let key = try await keyStore.load(vaultID: metadata.vaultID, keyID: metadata.activeKeyID)
        guard try unlockedGeneration() == expectedGeneration else {
            throw VaultStorageError.unlockSuperseded
        }

        let context = PayloadContext(
            vaultID: metadata.vaultID,
            keyID: metadata.activeKeyID,
            recordKind: .control,
            recordID: metadata.vaultID
        )
        let controlBytes = try PayloadEnvelope.open(metadata.controlEnvelope, using: key, context: context)
        let control = try JSONDecoder().decode(VaultControlPayload.self, from: controlBytes)
        guard control.version == 1,
              control.vaultID == metadata.vaultID,
              control.keyID == metadata.activeKeyID else {
            throw VaultStorageError.corruptVault
        }
        let kit = try RecoveryKit(vaultID: metadata.vaultID, keyID: metadata.activeKeyID, key: key)
        try RecoveryKitFileWriter.write(try kit.encoded(), to: path)
    }

    func saveCalendar(_ calendar: LocalCalendar) throws {
        let generation = try unlockedGeneration()
        let context = PayloadContext(
            vaultID: try currentVaultID(),
            keyID: try currentKeyID(),
            recordKind: .calendar,
            recordID: calendar.id
        )
        let envelope = try keySession.seal(
            VaultPayloadCodec.encode(calendar),
            context: context,
            expectedGeneration: generation
        )
        try saveCalendar(id: calendar.id, envelope: envelope)
    }

    func saveEvent(
        _ event: Event,
        recurrence: RecurrenceRule? = nil,
        cancellations: Set<EventOccurrenceKey> = []
    ) throws {
        let generation = try unlockedGeneration()
        let hasDuplicateUID = try events().contains { existing in
            existing.event.id != event.id &&
                existing.event.calendarID == event.calendarID &&
                existing.event.uid == event.uid
        }
        guard !hasDuplicateUID else { throw VaultStorageError.duplicateUID }
        if let recurrence {
            _ = try RecurringSeries(event: event, rule: recurrence, cancellations: cancellations)
        } else if !cancellations.isEmpty {
            throw DomainValidationError.invalidRecurrence
        }
        let vaultID = try currentVaultID()
        let keyID = try currentKeyID()
        let context = PayloadContext(
            vaultID: vaultID,
            keyID: keyID,
            recordKind: .event,
            recordID: event.id,
            parentID: event.calendarID
        )
        let envelope = try keySession.seal(
            VaultPayloadCodec.encode(event, recurrence: recurrence),
            context: context,
            expectedGeneration: generation
        )
        let encryptedExceptions = try cancellations.map { key -> (UUID, Data) in
            let cancellation = EventCancellation(key: key)
            let exceptionID = UUID()
            let exceptionContext = PayloadContext(
                vaultID: vaultID,
                keyID: keyID,
                recordKind: .eventException,
                recordID: exceptionID,
                parentID: event.id
            )
            return (exceptionID, try keySession.seal(
                VaultPayloadCodec.encode(cancellation),
                context: exceptionContext,
                expectedGeneration: generation
            ))
        }

        try connection.execute("BEGIN IMMEDIATE")
        do {
            try saveEvent(id: event.id, calendarID: event.calendarID, envelope: envelope)
            try deleteExceptions(eventID: event.id)
            for (exceptionID, exceptionEnvelope) in encryptedExceptions {
                try insertException(id: exceptionID, eventID: event.id, envelope: exceptionEnvelope)
            }
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    func importEvents(_ importedEvents: [Event], into calendarID: UUID) throws {
        let generation = try unlockedGeneration()
        guard try calendarRecords().contains(where: { $0.id == calendarID }),
              importedEvents.allSatisfy({ $0.calendarID == calendarID }) else {
            throw VaultStorageError.corruptVault
        }
        let existingUIDs = Set(try events().filter { $0.event.calendarID == calendarID }.map(\.event.uid))
        let importedUIDs = importedEvents.map(\.uid)
        guard existingUIDs.isDisjoint(with: importedUIDs),
              Set(importedUIDs).count == importedUIDs.count else {
            throw VaultStorageError.duplicateUID
        }
        let vaultID = try currentVaultID()
        let keyID = try currentKeyID()
        let encrypted = try importedEvents.map { event -> (UUID, UUID, Data) in
            let context = PayloadContext(
                vaultID: vaultID,
                keyID: keyID,
                recordKind: .event,
                recordID: event.id,
                parentID: calendarID
            )
            return (
                event.id,
                calendarID,
                try keySession.seal(
                    VaultPayloadCodec.encode(event, recurrence: nil),
                    context: context,
                    expectedGeneration: generation
                )
            )
        }
        try connection.execute("BEGIN IMMEDIATE")
        do {
            for (id, parentID, envelope) in encrypted {
                try saveEvent(id: id, calendarID: parentID, envelope: envelope)
            }
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    func calendars() throws -> [LocalCalendar] {
        let generation = try unlockedGeneration()
        let vaultID = try currentVaultID()
        let keyID = try currentKeyID()
        do {
            return try calendarRecords().map { record in
                let context = PayloadContext(
                    vaultID: vaultID,
                    keyID: keyID,
                    recordKind: .calendar,
                    recordID: record.id
                )
                let payload = try keySession.open(record.envelope, context: context, expectedGeneration: generation)
                return try VaultPayloadCodec.decodeCalendar(payload, id: record.id)
            }
        } catch {
            return try failClosed(error)
        }
    }

    func events() throws -> [VaultEvent] {
        let generation = try unlockedGeneration()
        let vaultID = try currentVaultID()
        let keyID = try currentKeyID()
        do {
            return try eventRecords().map { record in
                let context = PayloadContext(
                    vaultID: vaultID,
                    keyID: keyID,
                    recordKind: .event,
                    recordID: record.id,
                    parentID: record.calendarID
                )
                let payload = try keySession.open(record.envelope, context: context, expectedGeneration: generation)
                let base = try VaultPayloadCodec.decodeEvent(payload, id: record.id, calendarID: record.calendarID)
                let cancellations = try exceptionRecords(eventID: record.id).reduce(into: Set<EventOccurrenceKey>()) { result, exception in
                    let exceptionContext = PayloadContext(
                        vaultID: vaultID,
                        keyID: keyID,
                        recordKind: .eventException,
                        recordID: exception.id,
                        parentID: record.id
                    )
                    let exceptionPayload = try keySession.open(
                        exception.envelope,
                        context: exceptionContext,
                        expectedGeneration: generation
                    )
                    let cancellation = try VaultPayloadCodec.decodeCancellation(exceptionPayload, eventID: record.id)
                    result.insert(cancellation.key)
                }
                if let recurrence = base.recurrence {
                    _ = try RecurringSeries(event: base.event, rule: recurrence, cancellations: cancellations)
                } else if !cancellations.isEmpty {
                    throw VaultPayloadCodecError.invalidPayload
                }
                return VaultEvent(event: base.event, recurrence: base.recurrence, cancellations: cancellations)
            }
        } catch {
            return try failClosed(error)
        }
    }

    func events(matching query: EventSearchQuery) throws -> [VaultEvent] {
        let candidates = try events().filter { value in
            if let calendarIDs = query.calendarIDs, !calendarIDs.contains(value.event.calendarID) {
                return false
            }
            let needle = EventSearch.normalized(query.text ?? "")
            return needle.isEmpty || EventSearch.normalized(value.event.title).contains(needle)
        }
        let engine = RecurrenceEngine()
        var matches: [VaultEvent] = []
        for value in candidates {
            if let recurrence = value.recurrence {
                let series = try RecurringSeries(
                    event: value.event,
                    rule: recurrence,
                    cancellations: value.cancellations
                )
                if try !engine.expand(series, in: query.timeRange).isEmpty {
                    matches.append(value)
                }
            } else if !EventSearch.matching([value.event], query: query).isEmpty {
                matches.append(value)
            }
        }
        return matches.sorted { $0.event.id.uuidString < $1.event.id.uuidString }
    }

    func removeEvent(id: UUID) throws {
        _ = try unlockedGeneration()
        try deleteEvent(id: id)
    }

    func removeCalendar(id: UUID) throws {
        _ = try unlockedGeneration()
        try connection.execute("BEGIN IMMEDIATE")
        do {
            try deleteEvents(calendarID: id)
            try deleteCalendar(id: id)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    func migrate() throws {
        let currentVersion = try connection.userVersion()
        guard currentVersion <= Self.schemaVersion else {
            throw SQLiteVaultError.unsupportedSchemaVersion(currentVersion)
        }
        if currentVersion == Self.schemaVersion {
            try validateMetadataSchemaVersion()
            if case .unlocked = accessState {} else if case .unlocking = accessState {} else {
                if try metadata() == nil {
                    accessState = try hasBusinessRecords() ? .corrupt : .notCreated
                } else {
                    accessState = .locked
                }
            }
            return
        }

        try connection.execute("BEGIN IMMEDIATE")
        do {
            try connection.execute(Self.initialSchema)
            try connection.execute("PRAGMA user_version = 1")
            try connection.execute("COMMIT")
            accessState = .notCreated
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    func createVault(vaultID: UUID, keyID: UUID, controlEnvelope: Data) throws {
        try validate(id: vaultID)
        try validate(id: keyID)
        try validate(envelope: controlEnvelope)
        let statement = try connection.prepare(
            "INSERT INTO vault_meta(singleton, vault_id, schema_version, active_key_id, control_envelope) VALUES(1, ?1, ?2, ?3, ?4)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(vaultID, to: statement, at: 1)
        try bind(Int64(Self.schemaVersion), to: statement, at: 2)
        try bind(keyID, to: statement, at: 3)
        try bind(controlEnvelope, to: statement, at: 4)
        try stepDone(statement)
    }

    func metadata() throws -> VaultMetadata? {
        let statement = try connection.prepare(
            "SELECT vault_id, active_key_id, control_envelope, schema_version FROM vault_meta WHERE singleton = 1"
        )
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw connection.failure(status) }

        let schemaVersion = sqlite3_column_int64(statement, 3)
        guard schemaVersion == Int64(Self.schemaVersion) else {
            throw SQLiteVaultError.schemaMismatch
        }
        return VaultMetadata(
            vaultID: try uuidColumn(statement, index: 0),
            activeKeyID: try uuidColumn(statement, index: 1),
            controlEnvelope: try dataColumn(statement, index: 2)
        )
    }

    func insertCalendar(id: UUID, envelope: Data) throws {
        try insertRecord(sql: "INSERT INTO calendars(id, payload_envelope) VALUES(?1, ?2)", id: id, envelope: envelope)
    }

    func saveCalendar(id: UUID, envelope: Data) throws {
        try validate(id: id)
        try validate(envelope: envelope)
        let statement = try connection.prepare(
            "INSERT INTO calendars(id, payload_envelope) VALUES(?1, ?2) ON CONFLICT(id) DO UPDATE SET payload_envelope = excluded.payload_envelope"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try bind(envelope, to: statement, at: 2)
        try stepDone(statement)
    }

    func insertEvent(id: UUID, calendarID: UUID, envelope: Data) throws {
        try validate(id: id)
        try validate(id: calendarID)
        try validate(envelope: envelope)
        let statement = try connection.prepare(
            "INSERT INTO events(id, calendar_id, payload_envelope) VALUES(?1, ?2, ?3)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try bind(calendarID, to: statement, at: 2)
        try bind(envelope, to: statement, at: 3)
        try stepDone(statement)
    }

    func insertException(id: UUID, eventID: UUID, envelope: Data) throws {
        try validate(id: id)
        try validate(id: eventID)
        try validate(envelope: envelope)
        let statement = try connection.prepare(
            "INSERT INTO event_exceptions(id, event_id, payload_envelope) VALUES(?1, ?2, ?3)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try bind(eventID, to: statement, at: 2)
        try bind(envelope, to: statement, at: 3)
        try stepDone(statement)
    }

    func exceptionRecords(eventID: UUID) throws -> [VaultExceptionRecord] {
        try validate(id: eventID)
        let statement = try connection.prepare(
            "SELECT id, event_id, payload_envelope FROM event_exceptions WHERE event_id = ?1 ORDER BY id"
        )
        defer { sqlite3_finalize(statement) }
        try bind(eventID, to: statement, at: 1)
        var records: [VaultExceptionRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW else { throw connection.failure(status) }
            records.append(VaultExceptionRecord(
                id: try uuidColumn(statement, index: 0),
                eventID: try uuidColumn(statement, index: 1),
                envelope: try dataColumn(statement, index: 2)
            ))
        }
    }

    func deleteExceptions(eventID: UUID) throws {
        try validate(id: eventID)
        let statement = try connection.prepare("DELETE FROM event_exceptions WHERE event_id = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(eventID, to: statement, at: 1)
        try stepDone(statement)
    }

    func updateEvent(id: UUID, envelope: Data) throws {
        try validate(id: id)
        try validate(envelope: envelope)
        let statement = try connection.prepare("UPDATE events SET payload_envelope = ?1 WHERE id = ?2")
        defer { sqlite3_finalize(statement) }
        try bind(envelope, to: statement, at: 1)
        try bind(id, to: statement, at: 2)
        try stepDone(statement)
        guard sqlite3_changes(connection.handle) == 1 else { throw SQLiteVaultError.missingRecord }
    }

    func saveEvent(id: UUID, calendarID: UUID, envelope: Data) throws {
        try validate(id: id)
        try validate(id: calendarID)
        try validate(envelope: envelope)
        let statement = try connection.prepare(
            "INSERT INTO events(id, calendar_id, payload_envelope) VALUES(?1, ?2, ?3) " +
                "ON CONFLICT(id) DO UPDATE SET calendar_id = excluded.calendar_id, payload_envelope = excluded.payload_envelope"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try bind(calendarID, to: statement, at: 2)
        try bind(envelope, to: statement, at: 3)
        try stepDone(statement)
    }

    func payload(table: VaultPayloadTable, id: UUID) throws -> Data? {
        try validate(id: id)
        let statement = try connection.prepare(table.selectSQL)
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw connection.failure(status) }
        return try dataColumn(statement, index: 0)
    }

    func calendarRecords() throws -> [VaultCalendarRecord] {
        let statement = try connection.prepare("SELECT id, payload_envelope FROM calendars ORDER BY id")
        defer { sqlite3_finalize(statement) }
        var records: [VaultCalendarRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW else { throw connection.failure(status) }
            records.append(VaultCalendarRecord(
                id: try uuidColumn(statement, index: 0),
                envelope: try dataColumn(statement, index: 1)
            ))
        }
    }

    func eventRecords() throws -> [VaultEventRecord] {
        let statement = try connection.prepare("SELECT id, calendar_id, payload_envelope FROM events ORDER BY id")
        defer { sqlite3_finalize(statement) }
        var records: [VaultEventRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW else { throw connection.failure(status) }
            records.append(VaultEventRecord(
                id: try uuidColumn(statement, index: 0),
                calendarID: try uuidColumn(statement, index: 1),
                envelope: try dataColumn(statement, index: 2)
            ))
        }
    }

    private func hasBusinessRecords() throws -> Bool {
        for table in ["calendars", "events", "event_exceptions"] {
            let statement = try connection.prepare("SELECT 1 FROM \(table) LIMIT 1")
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { return true }
            guard status == SQLITE_DONE else { throw connection.failure(status) }
        }
        return false
    }

    func deleteEvent(id: UUID) throws {
        try deleteRecord(sql: "DELETE FROM events WHERE id = ?1", id: id)
    }

    func deleteCalendar(id: UUID) throws {
        try deleteRecord(sql: "DELETE FROM calendars WHERE id = ?1", id: id)
    }

    private func deleteEvents(calendarID: UUID) throws {
        let statement = try connection.prepare("DELETE FROM events WHERE calendar_id = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(calendarID, to: statement, at: 1)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw connection.failure(status) }
    }

    private func unlockedGeneration() throws -> UUID {
        guard case let .unlocked(generation) = accessState,
              keySession.isUnlocked,
              keySession.generation == generation else {
            throw VaultStorageError.locked
        }
        return generation
    }

    private func currentVaultID() throws -> UUID {
        guard let metadata = try metadata() else { throw VaultStorageError.corruptVault }
        return metadata.vaultID
    }

    private func currentKeyID() throws -> UUID {
        guard let metadata = try metadata() else { throw VaultStorageError.corruptVault }
        return metadata.activeKeyID
    }

    private func failClosed<Value>(_ error: Error) throws -> Value {
        if let error = error as? SQLiteVaultError {
            throw error
        }
        if let error = error as? VaultKeySessionError, error == .locked || error == .staleGeneration {
            throw VaultStorageError.locked
        }
        if let error = error as? VaultPayloadCodecError, error == .timeZoneRulesChanged {
            throw VaultStorageError.timeZoneRulesChanged
        }
        _ = keySession.lock()
        accessState = .corrupt
        throw VaultStorageError.corruptVault
    }

    func integrityCheck() throws {
        let statement = try connection.prepare("PRAGMA integrity_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok"
        else {
            throw SQLiteVaultError.integrityFailure
        }
    }

    func foreignKeyCheck() throws {
        let statement = try connection.prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return }
        if status == SQLITE_ROW { throw SQLiteVaultError.foreignKeyFailure }
        throw connection.failure(status)
    }

    func userVersion() throws -> Int32 {
        try connection.userVersion()
    }

    private func validateMetadataSchemaVersion() throws {
        let statement = try connection.prepare("SELECT schema_version FROM vault_meta WHERE singleton = 1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return }
        guard status == SQLITE_ROW,
              sqlite3_column_int64(statement, 0) == Int64(Self.schemaVersion)
        else {
            throw SQLiteVaultError.schemaMismatch
        }
    }

    private func insertRecord(sql: String, id: UUID, envelope: Data) throws {
        try validate(id: id)
        try validate(envelope: envelope)
        let statement = try connection.prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try bind(envelope, to: statement, at: 2)
        try stepDone(statement)
    }

    private func deleteRecord(sql: String, id: UUID) throws {
        try validate(id: id)
        let statement = try connection.prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try stepDone(statement)
        guard sqlite3_changes(connection.handle) == 1 else { throw SQLiteVaultError.missingRecord }
    }

    private func validate(id: UUID) throws {
        guard Self.uuidData(id).count == 16 else { throw SQLiteVaultError.invalidIdentifier }
    }

    private func validate(envelope: Data) throws {
        guard (Self.minimumEnvelopeSize...Self.maximumEnvelopeSize).contains(envelope.count) else {
            throw SQLiteVaultError.invalidEnvelope
        }
    }

    private func bind(_ id: UUID, to statement: OpaquePointer, at index: Int32) throws {
        try bind(Self.uuidData(id), to: statement, at: index)
    }

    private func bind(_ integer: Int64, to statement: OpaquePointer, at index: Int32) throws {
        let status = sqlite3_bind_int64(statement, index, integer)
        guard status == SQLITE_OK else { throw connection.failure(status) }
    }

    private func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
        }
        guard status == SQLITE_OK else { throw connection.failure(status) }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw connection.failure(status) }
    }

    private func uuidColumn(_ statement: OpaquePointer, index: Int32) throws -> UUID {
        let data = try dataColumn(statement, index: index)
        guard data.count == 16 else { throw SQLiteVaultError.invalidIdentifier }
        return UUID(uuid: (
            data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
            data[8], data[9], data[10], data[11], data[12], data[13], data[14], data[15]
        ))
    }

    private func dataColumn(_ statement: OpaquePointer, index: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0, count <= Self.maximumEnvelopeSize,
              let bytes = sqlite3_column_blob(statement, index)
        else {
            throw SQLiteVaultError.invalidEnvelope
        }
        return Data(bytes: bytes, count: count)
    }

    private static func uuidData(_ id: UUID) -> Data {
        var value = id.uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static let initialSchema = """
    CREATE TABLE vault_meta (
        singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton = 1),
        vault_id BLOB NOT NULL UNIQUE CHECK(typeof(vault_id) = 'blob' AND length(vault_id) = 16),
        schema_version INTEGER NOT NULL CHECK(schema_version = 1),
        active_key_id BLOB NOT NULL CHECK(typeof(active_key_id) = 'blob' AND length(active_key_id) = 16),
        control_envelope BLOB NOT NULL CHECK(typeof(control_envelope) = 'blob' AND length(control_envelope) BETWEEN 33 AND 131105)
    );
    CREATE TABLE calendars (
        id BLOB PRIMARY KEY NOT NULL CHECK(typeof(id) = 'blob' AND length(id) = 16),
        payload_envelope BLOB NOT NULL CHECK(typeof(payload_envelope) = 'blob' AND length(payload_envelope) BETWEEN 33 AND 131105)
    );
    CREATE TABLE events (
        id BLOB PRIMARY KEY NOT NULL CHECK(typeof(id) = 'blob' AND length(id) = 16),
        calendar_id BLOB NOT NULL CHECK(typeof(calendar_id) = 'blob' AND length(calendar_id) = 16),
        payload_envelope BLOB NOT NULL CHECK(typeof(payload_envelope) = 'blob' AND length(payload_envelope) BETWEEN 33 AND 131105),
        FOREIGN KEY(calendar_id) REFERENCES calendars(id) ON DELETE RESTRICT
    );
    CREATE TABLE event_exceptions (
        id BLOB PRIMARY KEY NOT NULL CHECK(typeof(id) = 'blob' AND length(id) = 16),
        event_id BLOB NOT NULL CHECK(typeof(event_id) = 'blob' AND length(event_id) = 16),
        payload_envelope BLOB NOT NULL CHECK(typeof(payload_envelope) = 'blob' AND length(payload_envelope) BETWEEN 33 AND 131105),
        FOREIGN KEY(event_id) REFERENCES events(id) ON DELETE CASCADE
    );
    CREATE INDEX events_calendar_id ON events(calendar_id);
    CREATE INDEX event_exceptions_event_id ON event_exceptions(event_id);
    """
}

private final class SQLiteConnection {
    let handle: OpaquePointer
    private let path: String

    init(path: String, requireNewFile: Bool = false) throws {
        if path != ":memory:" {
            try Self.preparePrivateDatabaseFile(path: path, requireNewFile: requireNewFile)
        }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_PRIVATECACHE
        let status = sqlite3_open_v2(path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw SQLiteVaultError.openFailed(status)
        }
        handle = database
        self.path = path
    }

    private static func preparePrivateDatabaseFile(path: String, requireNewFile: Bool) throws {
        let createFlags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let descriptor = path.withCString { open($0, createFlags, mode_t(S_IRUSR | S_IWUSR)) }
        if descriptor >= 0 {
            try validateAndCloseFileDescriptor(descriptor)
            return
        }
        if requireNewFile, errno == EEXIST { throw SQLiteVaultError.snapshotDestinationExists }
        guard errno == EEXIST else { throw SQLiteVaultError.filesystemFailure(errno) }

        let existingDescriptor = path.withCString { open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC) }
        guard existingDescriptor >= 0 else { throw SQLiteVaultError.filesystemFailure(errno) }
        try validateAndCloseFileDescriptor(existingDescriptor)
    }

    private static func validateAndCloseFileDescriptor(_ descriptor: Int32) throws {
        defer { close(descriptor) }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0 else {
            throw SQLiteVaultError.filesystemFailure(errno)
        }
        guard fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), fileStatus.st_uid == getuid() else {
            throw SQLiteVaultError.unsafeDatabaseFile
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw SQLiteVaultError.filesystemFailure(errno)
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func configure() throws {
        sqlite3_extended_result_codes(handle, 1)
        let timeoutStatus = sqlite3_busy_timeout(handle, 1_000)
        guard timeoutStatus == SQLITE_OK else { throw failure(timeoutStatus) }
        let defensiveStatus = kansolendar_sqlite_set_db_config(handle, SQLITE_DBCONFIG_DEFENSIVE, 1)
        guard defensiveStatus == SQLITE_OK else { throw failure(defensiveStatus) }
        // The system SQLite header marks extension loading as omitted/no-op.
        try execute("PRAGMA foreign_keys = ON")
        guard try pragmaInteger("PRAGMA foreign_keys") == 1 else {
            throw SQLiteVaultError.foreignKeyFailure
        }
        try execute("PRAGMA journal_mode = DELETE")
        try execute("PRAGMA synchronous = FULL")
        try execute("PRAGMA temp_store = MEMORY")
        try execute("PRAGMA trusted_schema = OFF")
    }

    func snapshot(to destinationPath: String) throws {
        guard destinationPath != ":memory:",
              URL(fileURLWithPath: destinationPath).standardizedFileURL.path
                != URL(fileURLWithPath: path).standardizedFileURL.path else {
            throw SQLiteVaultError.unsafeSnapshotDestination
        }

        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(atPath: destinationPath) }
        }
        let destination = try SQLiteConnection(path: destinationPath, requireNewFile: true)
        try destination.configure()

        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else {
            throw destination.failure(sqlite3_errcode(destination.handle))
        }
        let stepStatus = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard stepStatus == SQLITE_DONE else { throw failure(stepStatus) }
        guard finishStatus == SQLITE_OK else { throw destination.failure(finishStatus) }
        guard try destination.pragmaText("PRAGMA integrity_check") == "ok" else {
            throw SQLiteVaultError.integrityFailure
        }
        guard try !destination.hasRows("PRAGMA foreign_key_check") else {
            throw SQLiteVaultError.foreignKeyFailure
        }
        guard fsyncFile(at: destinationPath) else {
            throw SQLiteVaultError.filesystemFailure(errno)
        }
        completed = true
    }

    func replaceContents(from sourcePath: String) throws {
        let source = try SQLiteConnection(path: sourcePath)
        try source.configure()
        guard try source.pragmaText("PRAGMA integrity_check") == "ok",
              try !source.hasRows("PRAGMA foreign_key_check") else {
            throw SQLiteVaultError.integrityFailure
        }
        guard let backup = sqlite3_backup_init(handle, "main", source.handle, "main") else {
            throw failure(sqlite3_errcode(handle))
        }
        let stepStatus = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard stepStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
            throw SQLiteVaultError.restoreFailed
        }
        guard try pragmaText("PRAGMA integrity_check") == "ok",
              try !hasRows("PRAGMA foreign_key_check") else {
            throw SQLiteVaultError.integrityFailure
        }
    }

    func execute(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw failure(status) }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw failure(status) }
        return statement
    }

    func userVersion() throws -> Int32 {
        Int32(try pragmaInteger("PRAGMA user_version"))
    }

    func pragmaInteger(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else { throw failure(status) }
        return sqlite3_column_int64(statement, 0)
    }

    func pragmaText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw failure(status)
        }
        return String(cString: value)
    }

    func hasRows(_ sql: String) throws -> Bool {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure(status)
        }
    }

    private func fsyncFile(at path: String) -> Bool {
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return fsync(descriptor) == 0
    }

    func failure(_ status: Int32) -> SQLiteVaultError {
        let extendedStatus = sqlite3_extended_errcode(handle)
        if extendedStatus & 0xFF == SQLITE_CONSTRAINT {
            return .constraintViolation
        }
        return .databaseFailure(extendedStatus == SQLITE_OK ? status : extendedStatus)
    }
}
