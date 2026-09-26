import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Owns the Keychain boundary for per-vault encryption keys.
/// The returned key must stay inside the storage layer and only for an unlocked session.
internal actor KeychainVaultKeyStore: VaultKeyStore {
    static let service = "local.kansolendar.vault-key.v1"

    func create(vaultID: UUID, keyID: UUID) async throws -> SymmetricKey {
        let key = Self.generateDataEncryptionKey()
        try await install(key, vaultID: vaultID, keyID: keyID)
        return key
    }

    func install(_ key: SymmetricKey, vaultID: UUID, keyID: UUID) async throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        guard keyData.count == 32 else { throw VaultKeyStoreError.invalidKeyMaterial }
        let accessControl = try Self.makeUserPresenceAccessControl()
        let query = Self.makeAddQuery(
            keyData: keyData,
            vaultID: vaultID,
            keyID: keyID,
            accessControl: accessControl
        )

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Self.error(for: status)
        }
    }

    func load(vaultID: UUID, keyID: UUID) async throws -> SymmetricKey {
        let context = LAContext()
        context.localizedReason = "Unlock your Kansolendar calendar"
        let query = Self.makeReadQuery(vaultID: vaultID, keyID: keyID, context: context)

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw Self.error(for: status)
        }
        guard let keyData = item as? Data else {
            throw VaultKeyStoreError.invalidKeyMaterial
        }

        return try Self.makeDataEncryptionKey(from: keyData)
    }

    func delete(vaultID: UUID, keyID: UUID) async throws {
        let status = SecItemDelete(Self.makeDeleteQuery(vaultID: vaultID, keyID: keyID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status)
        }
    }

    static func generateDataEncryptionKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func makeDataEncryptionKey(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else {
            throw VaultKeyStoreError.invalidKeyMaterial
        }
        return SymmetricKey(data: data)
    }

    static func account(vaultID: UUID, keyID: UUID) -> String {
        "vault:\(vaultID.uuidString.lowercased()):key:\(keyID.uuidString.lowercased())"
    }

    static func makeUserPresenceAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            _ = error?.takeRetainedValue()
            throw VaultKeyStoreError.accessControlCreationFailed
        }
        return accessControl
    }

    static func makeAddQuery(
        keyData: Data,
        vaultID: UUID,
        keyID: UUID,
        accessControl: SecAccessControl
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(vaultID: vaultID, keyID: keyID),
            kSecAttrAccessControl as String: accessControl,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: keyData
        ]
    }

    private static func makeReadQuery(
        vaultID: UUID,
        keyID: UUID,
        context: LAContext
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(vaultID: vaultID, keyID: keyID),
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
    }

    private static func makeDeleteQuery(vaultID: UUID, keyID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(vaultID: vaultID, keyID: keyID),
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    static func error(for status: OSStatus) -> VaultKeyStoreError {
        switch status {
        case errSecItemNotFound:
            .missingKey
        case errSecDuplicateItem:
            .keyAlreadyExists
        case errSecUserCanceled:
            .userCancelled
        case errSecAuthFailed:
            .accessDenied
        case errSecMissingEntitlement:
            .missingEntitlement
        case errSecInteractionNotAllowed:
            .interactionNotAllowed
        default:
            .keychainFailure(status)
        }
    }
}

internal enum VaultKeyStoreError: Error, Equatable, Sendable {
    case missingKey
    case keyAlreadyExists
    case userCancelled
    case accessDenied
    case missingEntitlement
    case interactionNotAllowed
    case invalidKeyMaterial
    case accessControlCreationFailed
    case keychainFailure(OSStatus)
}
