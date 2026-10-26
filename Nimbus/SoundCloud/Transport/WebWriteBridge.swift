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

    private enum Page { case loading, ready, failed }

    private let webView: WKWebView
    private var page = Page.loading
    private var navigation: ObjectIdentifier?
    private var pendingLoads: [CheckedContinuation<Bool, Never>] = []
    private static let origin = URL(string: "https://soundcloud.com/robots.txt")!
    private static let loadTimeout: Duration = .seconds(15)

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 240), configuration: config)
        super.init()
        webView.navigationDelegate = self
        load()
    }

    // robots.txt rather than a real page: `fetch` only needs the origin and its cookie jar,
    // while loading the player pulls in service workers, audio components and a lot of console
    // noise from WebKit services the sandbox denies.
    private func load() {
        page = .loading
        let started = webView.load(URLRequest(url: Self.origin)).map(ObjectIdentifier.init)
        navigation = started
        Task { [weak self] in
            try? await Task.sleep(for: Self.loadTimeout)
            guard let self, self.navigation == started, self.page == .loading else { return }
            self.settle(.failed)
        }
    }

    struct Reply {
        let status: Int
        let url: String
        let body: String
        let cookies: String
    }

    /// Performs the request and reports what came back, or nil if the page couldn't run it.
    func send(method: String, url: String, token: String, json: String? = nil) async -> Reply? {
        guard await waitForLoad() else { return nil }

        let script = """
        let out = { status: -1, url: '', body: '', cookies: document.cookie };
        try {
            const headers = { Authorization: auth };
            if (json !== null) headers['Content-Type'] = 'application/json';
            const response = await fetch(url, {
                method: method,
                headers: headers,
                credentials: 'include',
                body: method === 'DELETE' ? undefined : (json ?? '')
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
            arguments: ["url": url, "method": method, "auth": "OAuth \(token)",
                        "json": json.map { $0 as Any } ?? NSNull()],
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

    /// Rotates both auth cookies in the shared store, as the web player does on a 401; nil if the page couldn't run it.
    func refreshSession() async -> Int? {
        guard await waitForLoad() else { return nil }
        let script = """
        try {
            const response = await fetch('/n/api/refresh-token', { method: 'POST', credentials: 'include' });
            return response.status;
        } catch (error) {
            return -1;
        }
        """
        let result = try? await webView.callAsyncJavaScript(script, contentWorld: .page)
        let status = (result as? Int) ?? (result as? Double).map(Int.init) ?? -1
        return status == -1 ? nil : status
    }

    /// False if the page can't come up; never hangs, since the token refresh parks every 401 behind it.
    private func waitForLoad() async -> Bool {
        if page == .failed { load() }
        if page == .ready { return true }
        return await withCheckedContinuation { pendingLoads.append($0) }
    }

    private func settle(_ outcome: Page) {
        page = outcome
        let waiting = pendingLoads
        pendingLoads.removeAll()
        waiting.forEach { $0.resume(returning: outcome == .ready) }
    }

    private func finish(_ finished: ObjectIdentifier?, succeeded: Bool) {
        // A superseded load reports too, as a cancellation, and must not settle the one after it.
        guard finished == navigation, page == .loading else { return }
        let onOrigin = webView.url?.host()?.hasSuffix("soundcloud.com") ?? false
        settle(succeeded && onOrigin ? .ready : .failed)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let finished = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in finish(finished, succeeded: true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError: Error) {
        let finished = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in finish(finished, succeeded: false) }
    }

    // What an offline or DNS failure actually fires; without it the first load never settled.
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError: Error) {
        let finished = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in finish(finished, succeeded: false) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in settle(.failed) }
    }
}
