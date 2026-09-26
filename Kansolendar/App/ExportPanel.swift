import AppKit
import UniformTypeIdentifiers

@MainActor
enum ExportPanel {
    static func chooseBackupDestination() -> URL? {
        chooseDestination(
            title: "Save Encrypted Backup",
            message: "The backup contains encrypted payloads only. A separate recovery kit is required to open it on another Mac.",
            name: "Kansolendar-Backup.kansobackup",
            type: UTType(exportedAs: "local.kansolendar.backup", conformingTo: .data)
        )
    }

    static func chooseRecoveryKitDestination() -> URL? {
        chooseDestination(
            title: "Save Recovery Kit",
            message: "This file can decrypt the backup. Store it separately in a secure location.",
            name: "Kansolendar-Recovery.txt",
            type: .plainText
        )
    }

    static func chooseCalendarDestination(calendarName: String) -> URL? {
        chooseDestination(
            title: "Export Calendar",
            message: "This iCalendar file is not encrypted and may contain private event details.",
            name: "\(safeFilename(calendarName)).ics",
            type: .calendarEvent
        )
    }

    static func chooseBackupForRestore() -> URL? {
        chooseSource(
            title: "Choose Encrypted Backup",
            message: "The backup will be validated completely before your current vault is replaced.",
            types: [UTType(importedAs: "local.kansolendar.backup", conformingTo: .data), .data]
        )
    }

    static func chooseRecoveryKitForRestore() -> URL? {
        chooseSource(
            title: "Choose Matching Recovery Kit",
            message: "Select the recovery kit exported for this backup.",
            types: [.plainText]
        )
    }

    static func chooseCalendarToImport() -> URL? {
        chooseSource(
            title: "Import Calendar Events",
            message: "Only supported all-day and UTC events will be imported. Unsupported files are rejected without partial changes.",
            types: [.calendarEvent]
        )
    }

    private static func chooseDestination(title: String, message: String, name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.message = message
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.showsTagField = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func chooseSource(title: String, message: String, types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Kansolendar-Calendar" : cleaned
    }
}
