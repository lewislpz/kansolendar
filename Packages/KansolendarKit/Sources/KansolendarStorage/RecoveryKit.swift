import CryptoKit
import Darwin
import Foundation

internal struct RecoveryKit: Equatable, Sendable {
    static let marker = "KANSOLENDAR-RECOVERY-KIT"
    static let currentVersion = 1
    static let maximumEncodedSize = 512

    let vaultID: UUID
    let keyID: UUID
    private let keyData: Data

    init(vaultID: UUID, keyID: UUID, key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        guard keyData.count == 32 else { throw RecoveryKitError.invalidKeyMaterial }
        self.vaultID = vaultID
        self.keyID = keyID
        self.keyData = keyData
    }

    private init(vaultID: UUID, keyID: UUID, keyData: Data) throws {
        guard keyData.count == 32 else { throw RecoveryKitError.invalidKeyMaterial }
        self.vaultID = vaultID
        self.keyID = keyID
        self.keyData = keyData
    }

    func encoded() throws -> Data {
        let text = """
        \(Self.marker)
        version:\(Self.currentVersion)
        vault-id:\(vaultID.uuidString.lowercased())
        key-id:\(keyID.uuidString.lowercased())
        key-base64:\(keyData.base64EncodedString())

        """
        guard let data = text.data(using: .utf8), data.count <= Self.maximumEncodedSize else {
            throw RecoveryKitError.malformed
        }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedSize,
              let text = String(data: data, encoding: .utf8),
              text.data(using: .utf8) == data else {
            throw RecoveryKitError.malformed
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 6, lines[0] == Substring(marker), lines[5].isEmpty else {
            throw RecoveryKitError.malformed
        }
        let fields = try parseFields(lines[1...4])
        guard fields["version"] == String(currentVersion) else {
            throw RecoveryKitError.unsupportedVersion
        }
        guard let vaultText = fields["vault-id"], let vaultID = UUID(uuidString: vaultText),
              let keyText = fields["key-id"], let keyID = UUID(uuidString: keyText),
              let encodedKey = fields["key-base64"],
              let keyData = Data(base64Encoded: encodedKey, options: []) else {
            throw RecoveryKitError.malformed
        }
        return try Self(vaultID: vaultID, keyID: keyID, keyData: keyData)
    }

    func makeKey() throws -> SymmetricKey {
        guard keyData.count == 32 else { throw RecoveryKitError.invalidKeyMaterial }
        return SymmetricKey(data: keyData)
    }

    private static func parseFields(_ lines: ArraySlice<Substring>) throws -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { throw RecoveryKitError.malformed }
            let name = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard ["version", "vault-id", "key-id", "key-base64"].contains(name),
                  !value.isEmpty,
                  fields.updateValue(value, forKey: name) == nil else {
                throw RecoveryKitError.malformed
            }
        }
        guard fields.count == 4 else { throw RecoveryKitError.malformed }
        return fields
    }
}

internal enum RecoveryKitError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    case invalidKeyMaterial
    case vaultMismatch
    case destinationExists
    case filesystemFailure(Int32)
}

internal enum RecoveryKitFileWriter {
    static func write(_ data: Data, to path: String) throws {
        let descriptor = path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw RecoveryKitError.destinationExists }
            throw RecoveryKitError.filesystemFailure(errno)
        }

        var completed = false
        defer {
            close(descriptor)
            if !completed { unlink(path) }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw RecoveryKitError.filesystemFailure(errno) }
                written += result
            }
        }
        guard fsync(descriptor) == 0 else { throw RecoveryKitError.filesystemFailure(errno) }
        completed = true
    }
}
