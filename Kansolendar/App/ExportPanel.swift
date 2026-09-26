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
}
