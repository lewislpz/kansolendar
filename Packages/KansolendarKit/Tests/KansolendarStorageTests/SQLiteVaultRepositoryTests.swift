import CryptoKit
import Foundation
import KansolendarCore
@testable import KansolendarStorage
import Testing

@Suite("Encrypted vault repository")
struct SQLiteVaultRepositoryTests {
    @Test("app-facing state migrates storage and reports an empty vault")
    func initialStateIsNotCreated() async throws {
        let storage = try SQLiteVaultDatabase(path: ":memory:", keyStore: FixtureVaultKeyStore())
        let vault = KansolendarVault(storage: storage)

        #expect(try await vault.state() == .notCreated)
        #expect(try await vault.state() == .notCreated)
    }

    @Test("vault create, lock, unlock and domain CRUD preserve encrypted values")
    func vaultLifecycleAndCRUD() async throws {
        let keyStore = FixtureVaultKeyStore()
        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: keyStore)
        let vaultID = try await database.createVault()
        #expect(await database.vaultState().isUnlocked)

        let calendar = try LocalCalendar(
            name: "Personal",
            color: .green,
            sortOrder: 2,
            defaultTimeZone: TimeZoneID("Europe/Madrid")
        )
        try await database.saveCalendar(calendar)

        let event = try Event(
            calendarID: calendar.id,
            uid: "event-local-1",
            title: "Private planning",
            notes: "not stored as SQL text",
            location: "Home",
            time: .utc(try TimedEventTime(start: Instant(unixSeconds: -100), durationSeconds: 1_800))
        )
        let recurrence = try RecurrenceRule(frequency: .daily, interval: 2, end: .count(5))
        try await database.saveEvent(event, recurrence: recurrence)
        #expect(try await database.calendars() == [calendar])
        #expect(try await database.events() == [VaultEvent(event: event, recurrence: recurrence)])

        await database.lockVault()
        #expect(await database.vaultState() == .locked)
        do {
            _ = try await database.events()
            Issue.record("Locked vault must not return events")
        } catch let error as VaultStorageError {
            #expect(error == .locked)
        }

        try await database.unlockVault()
        #expect(await database.vaultState().isUnlocked)
        #expect(try await database.events() == [VaultEvent(event: event, recurrence: recurrence)])

        try await database.removeEvent(id: event.id)
        #expect(try await database.events().isEmpty)
        try await database.removeCalendar(id: calendar.id)
        #expect(try await database.calendars().isEmpty)
        #expect(try await database.metadata()?.vaultID == vaultID)
    }

    @Test("recurrence cancellations round trip encrypted and change expansion")
    func recurrenceCancellationsPersist() async throws {
        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: FixtureVaultKeyStore())
        _ = try await database.createVault()
        let vault = KansolendarVault(storage: database)
        let calendar = try LocalCalendar(name: "Repeating", defaultTimeZone: TimeZoneID("UTC"))
        try await database.saveCalendar(calendar)
        let start = Instant(unixSeconds: 0)
        let event = try Event(
            calendarID: calendar.id,
            uid: "daily-series",
            title: "Daily standup",
            time: .utc(try TimedEventTime(start: start, durationSeconds: 60))
        )
        let rule = try RecurrenceRule(frequency: .daily, end: .count(5))
        let cancelledStart = Instant(unixSeconds: 86_400)
        let cancellation = EventOccurrenceKey(eventID: event.id, originalStart: .instant(cancelledStart))

        try await database.saveEvent(event, recurrence: rule, cancellations: [cancellation])
        let stored = try #require(try await database.events().first)
        #expect(stored.cancellations == [cancellation])
        let series = try RecurringSeries(event: stored.event, rule: try #require(stored.recurrence), cancellations: stored.cancellations)
        let query = try EventTimeRange.instant(InstantRange(
            start: Instant(unixSeconds: 0),
            endExclusive: Instant(unixSeconds: 5 * 86_400)
        ))
        let occurrences = try RecurrenceEngine().expand(series, in: query)
        #expect(occurrences.count == 4)
        #expect(!occurrences.contains { $0.key.originalStart == .instant(cancelledStart) })

        let matchingRange = EventTimeRange.instant(try InstantRange(
            start: Instant(unixSeconds: 2 * 86_400),
            endExclusive: Instant(unixSeconds: 3 * 86_400)
        ))
        let matchingQuery = EventSearchQuery(text: "STANDUP", calendarIDs: [calendar.id], timeRange: matchingRange)
        #expect(try await vault.events(matching: matchingQuery).map(\.event.id) == [event.id])
        let cancelledRange = EventTimeRange.instant(try InstantRange(
            start: Instant(unixSeconds: 86_400),
            endExclusive: Instant(unixSeconds: 2 * 86_400)
        ))
        let cancelledQuery = EventSearchQuery(text: "standup", timeRange: cancelledRange)
        #expect(try await vault.events(matching: cancelledQuery).isEmpty)

        let oversizedRange = EventTimeRange.instant(try InstantRange(
            start: Instant(unixSeconds: 0),
            endExclusive: Instant(unixSeconds: 367 * 86_400)
        ))
        let oversizedQuery = EventSearchQuery(timeRange: oversizedRange)
        do {
            _ = try await vault.events(matching: oversizedQuery)
            Issue.record("Queries must honor the recurrence expansion budget")
        } catch let error as VaultError {
            #expect(error == .queryLimitExceeded)
        }

        let wrongSeriesKey = EventOccurrenceKey(eventID: UUID(), originalStart: .instant(cancelledStart))
        do {
            try await database.saveEvent(event, recurrence: rule, cancellations: [wrongSeriesKey])
            Issue.record("A cancellation belonging to another event must be rejected")
        } catch let error as DomainValidationError {
            #expect(error == .invalidRecurrence)
        }
        #expect(try await database.events().first?.cancellations == [cancellation])

        try await database.saveEvent(event, recurrence: rule)
        #expect(try await database.events().first?.cancellations.isEmpty == true)
    }

    @Test("missing key requires recovery and user cancellation stays locked")
    func missingAndCancelledKeysFailClosed() async throws {
        let keyStore = FixtureVaultKeyStore()
        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: keyStore)
        _ = try await database.createVault()
        await database.lockVault()

        await keyStore.setLoadError(.userCancelled)
        do {
            try await database.unlockVault()
            Issue.record("Cancelled unlock must not succeed")
        } catch let error as VaultKeyStoreError {
            #expect(error == .userCancelled)
        }
        #expect(await database.vaultState() == .locked)

        await keyStore.setLoadError(.missingKey)
        do {
            try await database.unlockVault()
            Issue.record("Missing key must require recovery")
        } catch let error as VaultStorageError {
            #expect(error == .recoveryRequired)
        }
        #expect(await database.vaultState() == .recoveryRequired)
    }

    @Test("authenticated payload corruption locks the vault without partial results")
    func corruptPayloadLocksVault() async throws {
        let keyStore = FixtureVaultKeyStore()
        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: keyStore)
        _ = try await database.createVault()
        let calendar = try LocalCalendar(name: "Private", defaultTimeZone: TimeZoneID("UTC"))
        try await database.saveCalendar(calendar)

        let raw = try #require(await database.payload(table: .calendar, id: calendar.id))
        var corrupted = raw
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0x01
        try await database.saveCalendar(id: calendar.id, envelope: corrupted)

        do {
            _ = try await database.calendars()
            Issue.record("Tampered payload must not be returned")
        } catch let error as VaultStorageError {
            #expect(error == .corruptVault)
        }
        #expect(await database.vaultState() == .corrupt)
    }

    @Test("UID uniqueness is enforced within a calendar but not globally")
    func uidUniquenessMatchesDomainRule() async throws {
        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: FixtureVaultKeyStore())
        _ = try await database.createVault()
        let firstCalendar = try LocalCalendar(name: "One", defaultTimeZone: TimeZoneID("UTC"))
        let secondCalendar = try LocalCalendar(name: "Two", defaultTimeZone: TimeZoneID("UTC"))
        try await database.saveCalendar(firstCalendar)
        try await database.saveCalendar(secondCalendar)

        let firstEvent = try makeEvent(calendarID: firstCalendar.id, uid: "shared-uid", title: "First")
        try await database.saveEvent(firstEvent)
        let duplicate = try makeEvent(calendarID: firstCalendar.id, uid: "shared-uid", title: "Duplicate")
        do {
            try await database.saveEvent(duplicate)
            Issue.record("Duplicate UID in one calendar must fail")
        } catch let error as VaultStorageError {
            #expect(error == .duplicateUID)
        }

        let otherCalendarEvent = try makeEvent(calendarID: secondCalendar.id, uid: "shared-uid", title: "Other calendar")
        try await database.saveEvent(otherCalendarEvent)
        #expect(try await database.events().count == 2)
    }

    @Test("deleting a calendar atomically removes its encrypted events and exceptions")
    func calendarDeletionCascadesContents() async throws {
        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: FixtureVaultKeyStore())
        _ = try await database.createVault()
        let deletedCalendar = try LocalCalendar(name: "Delete me", defaultTimeZone: TimeZoneID("UTC"))
        let keptCalendar = try LocalCalendar(name: "Keep me", defaultTimeZone: TimeZoneID("UTC"))
        try await database.saveCalendar(deletedCalendar)
        try await database.saveCalendar(keptCalendar)

        let deletedEvent = try makeEvent(calendarID: deletedCalendar.id, uid: "deleted", title: "Deleted")
        let keptEvent = try makeEvent(calendarID: keptCalendar.id, uid: "kept", title: "Kept")
        let recurrence = try RecurrenceRule(frequency: .daily, end: .count(2))
        let cancellation = EventOccurrenceKey(
            eventID: deletedEvent.id,
            originalStart: .instant(Instant(unixSeconds: 86_400))
        )
        try await database.saveEvent(deletedEvent, recurrence: recurrence, cancellations: [cancellation])
        try await database.saveEvent(keptEvent)

        try await database.removeCalendar(id: deletedCalendar.id)

        #expect(try await database.calendars() == [keptCalendar])
        #expect(try await database.events() == [VaultEvent(event: keptEvent, recurrence: nil)])
        try await database.foreignKeyCheck()
    }

    @Test("orphan payload rows cannot be mistaken for a new empty vault")
    func orphanRecordsBlockVaultCreation() async throws {
        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: FixtureVaultKeyStore())
        try await database.migrate()
        try await database.insertCalendar(id: UUID(), envelope: Data(repeating: 0xA1, count: 33))

        do {
            _ = try await database.createVault()
            Issue.record("Existing business records without vault metadata are corruption")
        } catch let error as VaultStorageError {
            #expect(error == .corruptVault)
        }
        #expect(await database.vaultState() == .corrupt)
    }

    @Test("production database directory and file use restrictive permissions")
    func productionPathUsesPrivatePermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try VaultDatabaseLocation.databaseURL(applicationSupportRoot: root)
        #expect(try VaultDatabaseLocation.databaseURL(applicationSupportRoot: root) == url)
        let database = try SQLiteVaultDatabase(path: url.path, keyStore: FixtureVaultKeyStore())
        _ = database

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let databaseAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((databaseAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("online snapshot preserves encrypted vault data and never overwrites a destination")
    func onlineSnapshotRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.sqlite")
        let snapshotURL = root.appendingPathComponent("snapshot.kansobackup")
        let keyStore = FixtureVaultKeyStore()
        let source = try SQLiteVaultDatabase(path: sourceURL.path, keyStore: keyStore)
        _ = try await source.createVault()
        let calendar = try LocalCalendar(name: "Snapshot private", defaultTimeZone: TimeZoneID("UTC"))
        try await source.saveCalendar(calendar)
        let event = try makeEvent(calendarID: calendar.id, uid: "snapshot-event", title: "Encrypted snapshot")
        try await source.saveEvent(event)

        try await source.createSnapshot(at: snapshotURL.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let snapshotBytes = try Data(contentsOf: snapshotURL)
        #expect(snapshotBytes.range(of: Data("Snapshot private".utf8)) == nil)
        #expect(snapshotBytes.range(of: Data("Encrypted snapshot".utf8)) == nil)

        let restored = try SQLiteVaultDatabase(path: snapshotURL.path, keyStore: keyStore)
        try await restored.unlockVault()
        #expect(try await restored.calendars() == [calendar])
        #expect(try await restored.events() == [VaultEvent(event: event, recurrence: nil)])

        do {
            try await source.createSnapshot(at: snapshotURL.path)
            Issue.record("Snapshot must not overwrite an existing destination")
        } catch let error as SQLiteVaultError {
            #expect(error == .snapshotDestinationExists)
        }
    }

    @Test("recovery export reauthenticates and writes a matching private kit")
    func recoveryKitExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyStore = FixtureVaultKeyStore()
        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: keyStore)
        let vaultID = try await database.createVault()
        let metadata = try #require(try await database.metadata())
        let destination = root.appendingPathComponent("recovery.txt")

        try await database.exportRecoveryKit(to: destination.path)
        let kit = try RecoveryKit.decode(Data(contentsOf: destination))
        #expect(kit.vaultID == vaultID)
        #expect(kit.keyID == metadata.activeKeyID)
        let storedKey = try await keyStore.load(vaultID: vaultID, keyID: metadata.activeKeyID)
        #expect(try kit.makeKey().withUnsafeBytes { Data($0) } == storedKey.withUnsafeBytes { Data($0) })

        do {
            try await database.exportRecoveryKit(to: destination.path)
            Issue.record("Recovery export must not overwrite an existing file")
        } catch let error as RecoveryKitError {
            #expect(error == .destinationExists)
        }
    }

    @Test("backup plus matching recovery kit replaces the active vault only after validation")
    func restoreBackupWithMatchingKit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try SQLiteVaultDatabase(
            path: root.appendingPathComponent("source.sqlite").path,
            keyStore: FixtureVaultKeyStore()
        )
        _ = try await source.createVault()
        let restoredCalendar = try LocalCalendar(name: "Recovered", defaultTimeZone: TimeZoneID("UTC"))
        try await source.saveCalendar(restoredCalendar)
        let backup = root.appendingPathComponent("source.kansobackup")
        let kit = root.appendingPathComponent("source-recovery.txt")
        try await source.createSnapshot(at: backup.path)
        try await source.exportRecoveryKit(to: kit.path)

        let target = try SQLiteVaultDatabase(
            path: root.appendingPathComponent("target.sqlite").path,
            keyStore: FixtureVaultKeyStore()
        )
        _ = try await target.createVault()
        let previousCalendar = try LocalCalendar(name: "Previous", defaultTimeZone: TimeZoneID("UTC"))
        try await target.saveCalendar(previousCalendar)

        try await target.restoreBackup(from: backup.path, recoveryKitData: Data(contentsOf: kit))

        #expect(try await target.calendars() == [restoredCalendar])
        #expect(await target.vaultState().isUnlocked)
    }

    @Test("wrong recovery kit preserves the active vault")
    func wrongRecoveryKitPreservesActiveVault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try SQLiteVaultDatabase(
            path: root.appendingPathComponent("source.sqlite").path,
            keyStore: FixtureVaultKeyStore()
        )
        _ = try await source.createVault()
        let backup = root.appendingPathComponent("source.kansobackup")
        try await source.createSnapshot(at: backup.path)

        let target = try SQLiteVaultDatabase(
            path: root.appendingPathComponent("target.sqlite").path,
            keyStore: FixtureVaultKeyStore()
        )
        _ = try await target.createVault()
        let previousCalendar = try LocalCalendar(name: "Must survive", defaultTimeZone: TimeZoneID("UTC"))
        try await target.saveCalendar(previousCalendar)
        let wrongKit = root.appendingPathComponent("wrong-recovery.txt")
        try await target.exportRecoveryKit(to: wrongKit.path)

        await #expect(throws: (any Error).self) {
            try await target.restoreBackup(from: backup.path, recoveryKitData: Data(contentsOf: wrongKit))
        }
        #expect(try await target.calendars() == [previousCalendar])
    }

    @Test("recovery kit restores a vault after its local key is missing")
    func restoreAfterMissingLocalKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = FixtureVaultKeyStore()
        let database = try SQLiteVaultDatabase(
            path: root.appendingPathComponent("vault.sqlite").path,
            keyStore: keyStore
        )
        _ = try await database.createVault()
        let calendar = try LocalCalendar(name: "Recover me", defaultTimeZone: TimeZoneID("UTC"))
        try await database.saveCalendar(calendar)
        let backup = root.appendingPathComponent("backup.kansobackup")
        let kit = root.appendingPathComponent("recovery.txt")
        try await database.createSnapshot(at: backup.path)
        try await database.exportRecoveryKit(to: kit.path)
        let metadata = try #require(try await database.metadata())
        await database.lockVault()
        try await keyStore.delete(vaultID: metadata.vaultID, keyID: metadata.activeKeyID)
        await #expect(throws: VaultStorageError.recoveryRequired) {
            try await database.unlockVault()
        }

        try await database.restoreBackup(from: backup.path, recoveryKitData: Data(contentsOf: kit))

        #expect(try await database.calendars() == [calendar])
        #expect(await database.vaultState().isUnlocked)
    }

    @Test("iCalendar import is atomic when UIDs conflict")
    func iCalendarImportIsAtomic() async throws {
        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: FixtureVaultKeyStore())
        _ = try await database.createVault()
        let calendar = try LocalCalendar(name: "Imports", defaultTimeZone: TimeZoneID("UTC"))
        try await database.saveCalendar(calendar)
        let first = try makeEvent(calendarID: calendar.id, uid: "duplicate", title: "First")
        let second = try makeEvent(calendarID: calendar.id, uid: "duplicate", title: "Second")

        await #expect(throws: VaultStorageError.duplicateUID) {
            try await database.importEvents([first, second], into: calendar.id)
        }
        #expect(try await database.events().isEmpty)
    }

    @Test("app-facing iCalendar export and import use private files")
    func iCalendarFileRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: FixtureVaultKeyStore())
        let vault = KansolendarVault(storage: database)
        _ = try await vault.createVault()
        let source = try LocalCalendar(name: "Source", defaultTimeZone: TimeZoneID("UTC"))
        let destination = try LocalCalendar(name: "Destination", defaultTimeZone: TimeZoneID("UTC"))
        try await vault.save(source)
        try await vault.save(destination)
        let event = try makeEvent(calendarID: source.id, uid: "portable", title: "Portable")
        try await vault.save(event)
        let file = root.appendingPathComponent("calendar.ics")

        try await vault.exportCalendar(id: source.id, to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await vault.importCalendarEvents(from: file, into: destination.id) == 1)
        let imported = try #require(try await vault.events().first { $0.event.calendarID == destination.id })
        #expect(imported.event.uid == event.uid)
        #expect(imported.event.title == event.title)
    }

    @Test("application support location rejects a symlinked vault directory")
    func rejectsSymlinkedVaultDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let link = root.appendingPathComponent("Kansolendar", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        do {
            _ = try VaultDatabaseLocation.databaseURL(applicationSupportRoot: root)
            Issue.record("Symlinked vault directory must not be followed")
        } catch let error as VaultDatabaseLocationError {
            switch error {
            case .unsafeDirectory:
                break
            case let .filesystemFailure(code):
                #expect(code != 0)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("vault.sqlite").path))
    }

    @Test("overlapping vault creation is rejected without replacing the active attempt")
    func overlappingCreationIsRejected() async throws {
        let keyStore = FixtureVaultKeyStore()
        await keyStore.setCreateDelay(50_000_000)
        let database = try SQLiteVaultDatabase(path: ":memory:", keyStore: keyStore)
        let firstCreation = Task { try await database.createVault() }
        try await Task.sleep(nanoseconds: 5_000_000)

        do {
            _ = try await database.createVault()
            Issue.record("Concurrent creation must not replace an in-flight attempt")
        } catch let error as VaultStorageError {
            #expect(error == .unlockInProgress)
        }
        _ = try await firstCreation.value
        #expect(await database.vaultState().isUnlocked)
    }

    @Test("app-facing vault boundary exposes domain data and privacy-safe errors")
    func publicVaultBoundary() async throws {
        let keyStore = FixtureVaultKeyStore()
        let storage = try SQLiteVaultDatabase(path: ":memory:", keyStore: keyStore)
        let vault = KansolendarVault(storage: storage)
        _ = try await vault.createVault()
        #expect(try await vault.state() == .unlocked)

        let calendar = try LocalCalendar(name: "Private", defaultTimeZone: TimeZoneID("UTC"))
        try await vault.save(calendar)
        #expect(try await vault.calendars() == [calendar])

        await vault.lock()
        do {
            _ = try await vault.calendars()
            Issue.record("App-facing API must not return plaintext while locked")
        } catch let error as VaultError {
            #expect(error == .locked)
        }

        await keyStore.setLoadError(.userCancelled)
        do {
            try await vault.unlock()
            Issue.record("Cancelled Keychain prompt must remain locked")
        } catch let error as VaultError {
            #expect(error == .authenticationCancelled)
        }
        #expect(try await vault.state() == .locked)
    }

    private func makeEvent(calendarID: UUID, uid: String, title: String) throws -> Event {
        try Event(
            calendarID: calendarID,
            uid: uid,
            title: title,
            time: .utc(try TimedEventTime(start: Instant(unixSeconds: 0), durationSeconds: 60))
        )
    }
}

private actor FixtureVaultKeyStore: VaultKeyStore {
    private var keys: [String: Data] = [:]
    private var loadError: VaultKeyStoreError?
    private var createDelayNanoseconds: UInt64 = 0

    func create(vaultID: UUID, keyID: UUID) async throws -> SymmetricKey {
        if createDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: createDelayNanoseconds)
        }
        let key = SymmetricKey(size: .bits256)
        keys[KeychainVaultKeyStore.account(vaultID: vaultID, keyID: keyID)] = key.withUnsafeBytes { Data($0) }
        return key
    }

    func install(_ key: SymmetricKey, vaultID: UUID, keyID: UUID) async throws {
        keys[KeychainVaultKeyStore.account(vaultID: vaultID, keyID: keyID)] = key.withUnsafeBytes { Data($0) }
    }

    func load(vaultID: UUID, keyID: UUID) async throws -> SymmetricKey {
        if let loadError { throw loadError }
        guard let data = keys[KeychainVaultKeyStore.account(vaultID: vaultID, keyID: keyID)] else {
            throw VaultKeyStoreError.missingKey
        }
        return try KeychainVaultKeyStore.makeDataEncryptionKey(from: data)
    }

    func delete(vaultID: UUID, keyID: UUID) async throws {
        keys[KeychainVaultKeyStore.account(vaultID: vaultID, keyID: keyID)] = nil
    }

    func setLoadError(_ error: VaultKeyStoreError?) {
        loadError = error
    }

    func setCreateDelay(_ nanoseconds: UInt64) {
        createDelayNanoseconds = nanoseconds
    }
}

private extension VaultAccessState {
    var isUnlocked: Bool {
        if case .unlocked = self { return true }
        return false
    }
}
