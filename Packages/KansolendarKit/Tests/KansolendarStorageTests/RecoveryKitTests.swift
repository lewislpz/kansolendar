import CryptoKit
import Foundation
import Testing
@testable import KansolendarStorage

@Suite("Recovery kit")
struct RecoveryKitTests {
    private let vaultID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let keyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let keyBytes = Data(0..<32)

    @Test("encodes a deterministic bounded text format and round trips the key")
    func roundTrip() throws {
        let kit = try RecoveryKit(vaultID: vaultID, keyID: keyID, key: SymmetricKey(data: keyBytes))
        let encoded = try kit.encoded()

        #expect(String(decoding: encoded, as: UTF8.self) == """
        KANSOLENDAR-RECOVERY-KIT
        version:1
        vault-id:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
        key-id:11111111-2222-3333-4444-555555555555
        key-base64:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=

        """)
        #expect(encoded.count <= RecoveryKit.maximumEncodedSize)

        let decoded = try RecoveryKit.decode(encoded)
        #expect(decoded == kit)
        let recoveredKey = try decoded.makeKey()
        #expect(recoveredKey.withUnsafeBytes { Data($0) } == keyBytes)
    }

    @Test("rejects truncation, duplicate or unknown fields, invalid keys, and future versions", arguments: [
        "",
        "KANSOLENDAR-RECOVERY-KIT\nversion:1\n",
        "KANSOLENDAR-RECOVERY-KIT\nversion:1\nversion:1\nvault-id:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\nkey-id:11111111-2222-3333-4444-555555555555\n",
        "KANSOLENDAR-RECOVERY-KIT\nversion:1\nvault-id:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\nkey-id:11111111-2222-3333-4444-555555555555\nunknown:value\n",
        "KANSOLENDAR-RECOVERY-KIT\nversion:1\nvault-id:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\nkey-id:11111111-2222-3333-4444-555555555555\nkey-base64:AQ==\n"
    ])
    func rejectsMalformed(_ text: String) {
        #expect(throws: RecoveryKitError.self) {
            try RecoveryKit.decode(Data(text.utf8))
        }
    }

    @Test("reports an unsupported version separately")
    func rejectsFutureVersion() {
        let text = """
        KANSOLENDAR-RECOVERY-KIT
        version:2
        vault-id:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
        key-id:11111111-2222-3333-4444-555555555555
        key-base64:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=

        """
        #expect(throws: RecoveryKitError.unsupportedVersion) {
            try RecoveryKit.decode(Data(text.utf8))
        }
    }

    @Test("rejects oversized input before parsing")
    func rejectsOversizedInput() {
        #expect(throws: RecoveryKitError.malformed) {
            try RecoveryKit.decode(Data(repeating: 0x41, count: RecoveryKit.maximumEncodedSize + 1))
        }
    }

    @Test("file writer creates a private file and never overwrites")
    func privateFileWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("recovery.txt")
        let payload = Data("secret fixture".utf8)

        try RecoveryKitFileWriter.write(payload, to: destination.path)
        #expect(try Data(contentsOf: destination) == payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: RecoveryKitError.destinationExists) {
            try RecoveryKitFileWriter.write(Data("replacement".utf8), to: destination.path)
        }
        #expect(try Data(contentsOf: destination) == payload)
    }
}
