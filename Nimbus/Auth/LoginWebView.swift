import SwiftUI
import WebKit

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
        webView.load(URLRequest(url: URL(string: "https://soundcloud.com/signin")!))
        // Cookies land in WKHTTPCookieStore asynchronously after login, so poll instead of
        // sampling once on didFinish (which races the store sync).
        context.coordinator.startPolling(webView.configuration.websiteDataStore.httpCookieStore)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onAuthenticated: (String) -> Void
        private var pollTask: Task<Void, Never>?
        private var done = false

        init(onAuthenticated: @escaping (String) -> Void) {
            self.onAuthenticated = onAuthenticated
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
