import SwiftUI
import WebKit

/// Logs into soundcloud.com in a real web context and harvests the `oauth_token`
/// cookie the site sets (also covers Google-SSO). The token is persisted to the Keychain.
struct LoginWebView: NSViewRepresentable {
    var onAuthenticated: () -> Void

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
        private let onAuthenticated: () -> Void
        private var pollTask: Task<Void, Never>?
        private var done = false
        /// Google/Apple/Facebook sign-in opens in a popup window. Without a UI delegate that serves
        /// one, WebKit silently drops `window.open`, so SSO accounts can't log in at all. The popup
        /// shares the parent's configuration — hence its cookie jar — so the token it earns lands in
        /// the same store the poller already watches.
        private var ssoWindow: NSWindow?

        init(onAuthenticated: @escaping () -> Void) {
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

            // Mirror SoundCloud cookies — crucially the `datadome` bot-protection cookie — into
            // URLSession's shared jar so api-v2 writes carry the same DataDome context the browser
            // does. Writes 403 without it; reads aren't gated. URLSession then rotates it for us.
            for cookie in cookies where cookie.domain.contains("soundcloud.com") {
                HTTPCookieStorage.shared.setCookie(cookie)
            }

            guard let token = cookies.first(where: {
                $0.name == "oauth_token" && $0.domain.contains("soundcloud.com")
            })?.value else { return }

            done = true
            pollTask?.cancel()
            Keychain.set(token, for: SoundCloudAPI.tokenAccount)
            onAuthenticated()
        }
    }
}
