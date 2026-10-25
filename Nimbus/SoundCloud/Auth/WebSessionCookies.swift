import Foundation
import WebKit

/// Copies the site's cookies — above all DataDome's — from the web view's jar into URLSession's.
/// Login does this as it polls, but the two jars stay separate afterwards, so a relaunch would
/// otherwise leave api-v2 writes without the bot-protection context and every PUT/POST 403s.
@MainActor
enum WebSessionCookies {
    static func sync() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies where cookie.domain.contains("soundcloud.com") {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    nonisolated enum Refresh: Sendable {
        case token(String)
        case rejected
        /// The refresh got no answer worth acting on; the session may well still be good.
        case unavailable
    }

    /// `oauth_token` is a 24-hour JWT; the HttpOnly `oauth_refresh_token` beside it buys the next one.
    static func refresh() async -> Refresh {
        guard await cookie("oauth_refresh_token") != nil else { return .rejected }
        let status = await WebWriteBridge.shared.refreshSession()
        if let status, (200..<300).contains(status), let token = await cookie("oauth_token") {
            await sync()
            return .token(token)
        }
        // The site's own refresh drops the cookie when SoundCloud refuses it, and keeps it on any other failure.
        return await cookie("oauth_refresh_token") == nil ? .rejected : .unavailable
    }

    private static func cookie(_ name: String) async -> String? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.first { $0.name == name && $0.domain.contains("soundcloud.com") }?.value
    }

    /// Drops the web session for real. Clearing the stored token alone isn't a sign-out: the web view
    /// keeps its cookies, and the next login screen would re-harvest the same token instantly.
    static func clear() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let soundcloud = records.filter { $0.displayName.contains("soundcloud") }
        await store.removeData(ofTypes: types, for: soundcloud)

        HTTPCookieStorage.shared.cookies?
            .filter { $0.domain.contains("soundcloud.com") }
            .forEach(HTTPCookieStorage.shared.deleteCookie)
    }

    /// Whether the DataDome cookie is present at all — its absence is the difference between
    /// "writes work" and "writes 403 with a captcha".
    static var hasBotProtectionCookie: Bool {
        HTTPCookieStorage.shared.cookies?.contains {
            $0.name.lowercased() == "datadome" && $0.domain.contains("soundcloud.com")
        } ?? false
    }
}
