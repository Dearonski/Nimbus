import Foundation
import Security

nonisolated enum Keychain {
    private static let service = "io.github.dearonski.Nimbus"

    /// Data Protection keychain scopes items to the app identifier (not the code
    /// signature), so debug rebuilds don't trigger a keychain password prompt.
    /// Requires the keychain-access-groups entitlement (see Nimbus.entitlements) plus a
    /// stable signing identity — otherwise SecItem fails with errSecMissingEntitlement (-34018).
    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query = baseQuery(account)

        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    static func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
