import Foundation
import Security

protocol SecretStoring {
    func string(for account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func remove(_ account: String) throws
}

enum SecretStoreError: LocalizedError {
    case unexpectedData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            return "The keychain item is not valid UTF-8."
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}

/// Small Keychain wrapper for provider credentials. The service is stable across
/// app updates, while Debug and Release remain isolated by bundle identifier.
struct KeychainSecretStore: SecretStoring {
    private let service: String

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "vip.eztool.StockBar") {
        self.service = "\(bundleIdentifier).credentials"
    }

    func string(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.unexpectedData
        }
        return value
    }

    func set(_ value: String, for account: String) throws {
        if value.isEmpty {
            try remove(account)
            return
        }
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw SecretStoreError.keychain(status)
        }
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
