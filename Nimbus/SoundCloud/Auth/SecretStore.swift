import CryptoKit
import Foundation
import os
import Security

// Not the keychain: without a Team ID it ties an item to the binary's hash, so every update asked for the password.
nonisolated enum SecretStore {
    private static let directory = URL.applicationSupportDirectory.appending(path: "Secrets", directoryHint: .isDirectory)
    private static let enclaveKeyFile = directory.appending(path: "enclave-key")
    private static let log = Logger(subsystem: "io.github.dearonski.Nimbus", category: "secrets")

    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    static func set(_ value: String, for account: String) {
        do {
            let sealed = try AES.GCM.seal(Data(value.utf8), using: sealingKey())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try sealed.combined?.write(to: file(for: account), options: .atomic)
        } catch {
            log.error("could not store \(account, privacy: .public): \(error, privacy: .public)")
        }
        cache.withLock { $0[account] = value }
    }

    static func get(_ account: String) -> String? {
        if let cached = cache.withLock({ $0[account] }) { return cached }
        guard let sealed = try? Data(contentsOf: file(for: account)) else { return migrateFromKeychain(account) }
        do {
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: sealingKey())
            let value = String(decoding: data, as: UTF8.self)
            cache.withLock { $0[account] = value }
            return value
        } catch {
            log.error("could not open \(account, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    static func remove(_ account: String) {
        try? FileManager.default.removeItem(at: file(for: account))
        LegacyKeychain.remove(account)
        cache.withLock { $0[account] = nil }
    }

    private static func file(for account: String) -> URL {
        directory.appending(path: account)
    }

    // The enclave key only works on this Mac, so the files are worthless copied off it or restored elsewhere.
    private static func sealingKey() throws -> SymmetricKey {
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        if let blob = try? Data(contentsOf: enclaveKeyFile) {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        } else {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try key.dataRepresentation.write(to: enclaveKeyFile, options: .atomic)
        }
        return try key.sharedSecretFromKeyAgreement(with: key.publicKey)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("nimbus-secrets".utf8),
                                     outputByteCount: 32)
    }

    private static func migrateFromKeychain(_ account: String) -> String? {
        guard let value = LegacyKeychain.get(account) else { return nil }
        set(value, for: account)
        LegacyKeychain.remove(account)
        return value
    }
}

/// Where 1.0 kept the token; read once on the way to `SecretStore`, then emptied.
private nonisolated enum LegacyKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.dearonski.Nimbus",
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    static func get(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
