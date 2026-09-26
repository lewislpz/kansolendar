import AppKit
import UniformTypeIdentifiers

@MainActor
enum ExportPanel {
    static func chooseBackupDestination() -> URL? {
        chooseDestination(
            title: "Guardar backup cifrado",
            message: "El backup contiene únicamente payloads cifrados. Necesita el kit de recuperación por separado para abrirse en otro Mac.",
            name: "Kansolendar-Backup.kansobackup",
            type: UTType(exportedAs: "local.kansolendar.backup", conformingTo: .data)
        )
    }

    static func chooseRecoveryKitDestination() -> URL? {
        chooseDestination(
            title: "Guardar kit de recuperación",
            message: "Este archivo permite descifrar el backup. Guárdalo separado y en un lugar seguro.",
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
