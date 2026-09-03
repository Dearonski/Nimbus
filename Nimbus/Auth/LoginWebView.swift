import SwiftUI
import WebKit

/// Copies the site's cookies from the web view's jar into URLSession's, which are otherwise
/// separate. Writes turned out not to need this — `Origin`/`Referer` are what DataDome inspects,
/// measured 03.09.2026 — so the mirroring is kept only because nothing has been shown to want it
/// gone; drop it once reads are confirmed indifferent too.
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
}

/// Logs into soundcloud.com in a real web context and harvests the `oauth_token`
/// cookie the site sets (also covers Google-SSO). The token is persisted to the Keychain.
struct LoginWebView: NSViewRepresentable {
    var onAuthenticated: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onAuthenticated: onAuthenticated) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://soundcloud.com/signin")!))
        // Cookies land in WKHTTPCookieStore asynchronously after login, so poll instead of
        // sampling once on didFinish (which races the store sync).
        context.coordinator.startPolling(webView.configuration.websiteDataStore.httpCookieStore)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onAuthenticated: (String) -> Void
        private var pollTask: Task<Void, Never>?
        private var done = false
        /// Google/Apple/Facebook sign-in opens in a popup window. Without a UI delegate that serves
        /// one, WebKit silently drops `window.open`, so SSO accounts can't log in at all. The popup
        /// shares the parent's configuration — hence its cookie jar — so the token it earns lands in
        /// the same store the poller already watches.
        private var ssoWindow: NSWindow?

        init(onAuthenticated: @escaping (String) -> Void) {
            self.onAuthenticated = onAuthenticated
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self

            let size = NSSize(width: windowFeatures.width?.doubleValue ?? 500,
                              height: windowFeatures.height?.doubleValue ?? 640)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Sign in"
            window.isReleasedWhenClosed = false
            window.contentView = popup
            window.center()
            window.makeKeyAndOrderFront(nil)
            ssoWindow = window
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            ssoWindow?.close()
            ssoWindow = nil
        }

        func startPolling(_ store: WKHTTPCookieStore) {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.harvest(store)
                    if self?.done ?? true { return }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        private func harvest(_ store: WKHTTPCookieStore) async {
            guard !done else { return }
            let cookies = await store.allCookies()

            // Mirror the site's cookies into URLSession's shared jar. See WebSessionCookies:
            // no longer load-bearing for writes, kept until reads are shown not to care either.
            for cookie in cookies where cookie.domain.contains("soundcloud.com") {
                HTTPCookieStorage.shared.setCookie(cookie)
            }

            guard let token = cookies.first(where: {
                $0.name == "oauth_token" && $0.domain.contains("soundcloud.com")
            })?.value else { return }

            done = true
            pollTask?.cancel()
            Keychain.set(token, for: SoundCloudAPI.tokenAccount)
            onAuthenticated(token)
        }
    }
}
