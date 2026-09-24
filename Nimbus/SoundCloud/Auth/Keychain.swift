import Foundation
import os
import Security

nonisolated enum Keychain {
    private static let service = "io.github.dearonski.Nimbus"

    // Not the Data Protection keychain: it needs `keychain-access-groups`, which only an Apple profile grants.
    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    // Read on every request: uncached, one declined access prompt came back on each of them.
    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query = baseQuery(account)

        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
        cache.withLock { $0[account] = value }
    }

    static func get(_ account: String) -> String? {
        if let cached = cache.withLock({ $0[account] }) { return cached }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        cache.withLock { $0[account] = value }
        return value
    }

    static func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        cache.withLock { $0[account] = nil }
    }
}
