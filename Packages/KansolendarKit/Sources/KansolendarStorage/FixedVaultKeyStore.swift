import CryptoKit
import Foundation

/// A short-lived validation boundary used only for a staged backup.
internal actor FixedVaultKeyStore: VaultKeyStore {
    private let vaultID: UUID
    private let keyID: UUID
    private let key: SymmetricKey

    init(vaultID: UUID, keyID: UUID, key: SymmetricKey) {
        self.vaultID = vaultID
        self.keyID = keyID
        self.key = key
    }

    func create(vaultID: UUID, keyID: UUID) async throws -> SymmetricKey {
        throw VaultKeyStoreError.accessDenied
    }

    func install(_ key: SymmetricKey, vaultID: UUID, keyID: UUID) async throws {
        throw VaultKeyStoreError.accessDenied
    }

    func load(vaultID: UUID, keyID: UUID) async throws -> SymmetricKey {
        guard vaultID == self.vaultID, keyID == self.keyID else {
            throw VaultKeyStoreError.missingKey
        }
        return key
    }

    func delete(vaultID: UUID, keyID: UUID) async throws {
        throw VaultKeyStoreError.accessDenied
    }
}
