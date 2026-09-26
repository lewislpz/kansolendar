import CryptoKit
import Foundation

internal protocol VaultKeyStore: Sendable {
    func create(vaultID: UUID, keyID: UUID) async throws -> SymmetricKey
    func install(_ key: SymmetricKey, vaultID: UUID, keyID: UUID) async throws
    func load(vaultID: UUID, keyID: UUID) async throws -> SymmetricKey
    func delete(vaultID: UUID, keyID: UUID) async throws
}
