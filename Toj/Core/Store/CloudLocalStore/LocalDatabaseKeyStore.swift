import Foundation
import GRDB
import os
import Security

nonisolated struct LocalDatabaseKeyStore {
    private let service: String
    let account: String

    init(service: String = "com.toj.cloud-db", account: String = "sqlcipher-key") {
        self.service = service
        self.account = account
    }

    static var usesTelegramFastUITestFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["TOJ_UI_FIXTURE"] == "telegram-fast"
        #else
        false
        #endif
    }

    static func currentEnvironment() -> LocalDatabaseKeyStore {
        usesTelegramFastUITestFixture
            ? LocalDatabaseKeyStore(
                service: "com.toj.cloud-db.ui-fixture",
                account: "sqlcipher-key"
            )
            : LocalDatabaseKeyStore()
    }

    func loadOrCreateKey() throws -> Data {
        if let existing = try loadKey() { return existing }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw KeychainError(status: randomStatus)
        }

        let data = Data(bytes)
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return data }
        if addStatus == errSecDuplicateItem, let existing = try loadKey() {
            return existing
        }
        throw KeychainError(status: addStatus)
    }

    /// Installs a known key during the one-time legacy-to-account storage migration. A different
    /// existing key is never overwritten: doing so would silently make a previously copied replica
    /// unreadable after an interrupted launch.
    func installKeyIfAbsent(_ data: Data) throws {
        guard data.count == 32 else { throw KeychainError(status: errSecParam) }
        if let existing = try loadKey() {
            guard existing == data else { throw KeychainError(status: errSecDuplicateItem) }
            return
        }
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem, try loadKey() == data { return }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func accountScoped(accountId: String) throws -> LocalDatabaseKeyStore {
        guard AccountCatalog.isValidAccountId(accountId) else {
            throw AccountCatalogError.invalidAccountIdentifier
        }
        let fixtureSuffix = usesTelegramFastUITestFixture ? ".ui-fixture" : ""
        return LocalDatabaseKeyStore(
            service: "com.toj.cloud-db.account\(fixtureSuffix)",
            account: "sqlcipher-key-\(accountId.lowercased())"
        )
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func loadKey() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
