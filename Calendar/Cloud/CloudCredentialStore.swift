import Foundation
import Security

/// Session capability never enters preferences, exports or application logs.
enum CloudCredentialStore {
    private static let service = "ru.local.GoldenGateCalendar.CloudSession.v1"
    private static let account = "render-session"
    static func read() throws -> String? {
        var value: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let text = String(data: data, encoding: .utf8) else {
            throw CloudError.message("Не удалось открыть сессию в Связке ключей. Войдите заново.")
        }
        return text
    }
    static func save(_ value: String?) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if let value {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData: Data(value.utf8)] as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else { throw CloudError.message("Не удалось сохранить сессию в Связке ключей.") }
            var item = query; item[kSecValueData] = Data(value.utf8); item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CloudError.message("Связка ключей не разрешила сохранить вход.") }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudError.message("Не удалось удалить сессию из Связки ключей.") }
        }
    }
}

/// Injection keeps authentication tests isolated from the user's real Keychain.
struct CloudCredentialAccess {
    var read: () throws -> String?
    var save: (String?) throws -> Void
    static var keychain: Self { Self(read: CloudCredentialStore.read, save: CloudCredentialStore.save) }
}
