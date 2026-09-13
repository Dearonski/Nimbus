import WebKit

/// Runs api-v2 writes inside a real web page instead of through URLSession.
///
/// DataDome profiles the whole caller — headers, TLS fingerprint, cookie history — so a URLSession
/// request answers 403 with a captcha even carrying the harvested `datadome` cookie. A `fetch` from
/// a loaded soundcloud.com page is indistinguishable from the web player, because it *is* the web
/// player's context: same cookie jar, same origin, same everything.
@MainActor
final class WebWriteBridge: NSObject, WKNavigationDelegate {
    /// One page for the whole app: the API is an actor, and spinning up a web view per request
    /// would also mean re-running DataDome's checks every time.
    static let shared = WebWriteBridge()

    private let webView: WKWebView
    private var loaded = false
    private var pendingLoads: [CheckedContinuation<Void, Never>] = []

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 240), configuration: config)
        super.init()
        webView.navigationDelegate = self
        // robots.txt rather than a real page: `fetch` only needs the origin and its cookie jar,
        // while loading the player pulls in service workers, audio components and a lot of console
        // noise from WebKit services the sandbox denies.
        webView.load(URLRequest(url: URL(string: "https://soundcloud.com/robots.txt")!))
    }

    struct Reply {
        let status: Int
        let url: String
        let body: String
        let cookies: String
    }

    /// Performs the request and reports what came back, or nil if the page couldn't run it.
    func send(method: String, url: String, token: String) async -> Reply? {
        await waitForLoad()

        let script = """
        let out = { status: -1, url: '', body: '', cookies: document.cookie };
        try {
            const response = await fetch(url, {
                method: method,
                headers: { Authorization: auth },
                credentials: 'include',
                body: method === 'DELETE' ? undefined : ''
            });
            out.status = response.status;
            out.url = response.url;
            try {
                out.body = (await response.text()).slice(0, 300);
            } catch (bodyError) {
                out.body = 'body unreadable: ' + bodyError;
            }
        } catch (error) {
            out.body = 'fetch threw: ' + error;
        }
        return out;
        """
        let result = try? await webView.callAsyncJavaScript(
            script,
            arguments: ["url": url, "method": method, "auth": "OAuth \(token)"],
            contentWorld: .page)
        guard let dict = result as? [String: Any] else { return nil }
        let status = (dict["status"] as? Int) ?? (dict["status"] as? Double).map(Int.init) ?? -1
        let cookies = (dict["cookies"] as? String) ?? ""
        let names = cookies.split(separator: ";")
            .compactMap { $0.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) }
        return Reply(status: status,
                     url: (dict["url"] as? String) ?? "",
                     body: (dict["body"] as? String) ?? "",
                     cookies: names.joined(separator: ","))
    }

    private func waitForLoad() async {
        guard !loaded else { return }
        await withCheckedContinuation { continuation in
            pendingLoads.append(continuation)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            loaded = true
            pendingLoads.forEach { $0.resume() }
            pendingLoads.removeAll()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError: Error) {
        Task { @MainActor in
            loaded = true
            pendingLoads.forEach { $0.resume() }
            pendingLoads.removeAll()
        }
    }
}
