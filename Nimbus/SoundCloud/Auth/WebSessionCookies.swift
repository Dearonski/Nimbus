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

    /// The `oauth_token` the web session currently holds, if any. A harvested token can be
    /// rejected while the browser session is still good — the site rotates it — so this is what
    /// makes a silent re-login possible instead of bouncing the user to the login screen.
    static func freshToken() async -> String? {
        await sync()
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.first {
            $0.name == "oauth_token" && $0.domain.contains("soundcloud.com")
        }?.value
    }

    /// Drops the web session for real. Clearing the Keychain alone isn't a sign-out: the web view
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
