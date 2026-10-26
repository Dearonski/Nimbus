import Foundation
import os

/// The signed-in session: the one owner of the token, and the one place it is renewed.
actor AuthSession {
    private static let account = "oauth_token"
    private static let log = Logger(subsystem: "io.github.dearonski.Nimbus", category: "api")
    /// The JWT is renewed this long before it runs out, so the daily expiry never meets a request.
    private static let renewalLead: TimeInterval = 60
    /// An offline renewal takes up to the bridge's load timeout; every request after it must not wait that long again.
    private static let unavailableBackoff: TimeInterval = 30

    private var renew: (@Sendable () async -> WebSessionCookies.Refresh)?
    private var onExpired: (@Sendable () async -> Void)?
    // Each refresh rotates the refresh token too, so a burst of 401s must share one or the rest spend a stale one.
    private var refreshing: Task<WebSessionCookies.Refresh, Never>?
    private var unavailableSince: Date?

    nonisolated var token: String? { SecretStore.get(Self.account) }

    nonisolated func store(_ token: String) {
        SecretStore.set(token, for: Self.account)
    }

    nonisolated func clear() {
        SecretStore.remove(Self.account)
    }

    func configure(renew: @escaping @Sendable () async -> WebSessionCookies.Refresh,
                   onExpired: @escaping @Sendable () async -> Void) {
        self.renew = renew
        self.onExpired = onExpired
    }

    /// The token to send: the stored one, renewed first when it is about to run out.
    func current() async -> String? {
        guard let token else { return nil }
        guard let expiry = Self.expiry(of: token), expiry.timeIntervalSinceNow < Self.renewalLead else { return token }
        switch await renewed(replacing: token) {
        case .token(let fresh): return fresh
        case .rejected: return nil
        // Sent anyway: the server may still take it, and a 401 then says so properly.
        case .unavailable: return token
        }
    }

    /// Signs out only when SoundCloud refused the refresh, not when it merely didn't get through.
    func renewed(replacing stale: String) async -> WebSessionCookies.Refresh {
        if let current = token, current != stale { return .token(current) }
        if let refreshing { return await refreshing.value }
        if let unavailableSince, Date.now.timeIntervalSince(unavailableSince) < Self.unavailableBackoff {
            return .unavailable
        }
        guard let renew else { return .unavailable }
        let task = Task { await renew() }
        refreshing = task
        let outcome = await task.value
        refreshing = nil
        switch outcome {
        case .token(let fresh):
            unavailableSince = nil
            store(fresh)
            Self.log.info("token refresh: renewed")
        case .rejected:
            Self.log.error("token refresh: rejected")
            await onExpired?()
        case .unavailable:
            unavailableSince = .now
            Self.log.error("token refresh: unavailable")
        }
        return outcome
    }

    /// Whether a 401 can be the token's age. A token that isn't a readable JWT might be, so it is renewed as before.
    nonisolated static func mayHaveExpired(_ token: String) -> Bool {
        guard let expiry = expiry(of: token) else { return true }
        return expiry.timeIntervalSinceNow < renewalLead
    }

    private nonisolated static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
