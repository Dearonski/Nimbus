import AppKit
import SwiftUI
import WebKit

// DataDome answers a doubted write with a captcha; as on the site, a person solves it in a frame
// whose cookie then lands in the writes' own jar.
@MainActor
final class CaptchaChallenge: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    static let shared = CaptchaChallenge()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    // The captcha page from a 403 body: `{"url": "https://geo.captcha-delivery.com/captcha/?..."}`.
    nonisolated static func url(in body: String) -> URL? {
        guard body.contains("captcha-delivery.com"),
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let string = object["url"] as? String else { return nil }
        return URL(string: string)
    }

    // True once solved; every write that hit the captcha meanwhile waits on the same window.
    func solve(_ captcha: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if window == nil { present(captcha) }
        }
    }

    private func present(_ captcha: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.add(self, name: "captcha")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .clear
        self.webView = webView
        webView.loadHTMLString(Self.page(for: captcha), baseURL: URL(string: "https://soundcloud.com/"))

        let host = NSHostingController(rootView: CaptchaSheet(webView: webView) { [weak self] in self?.finish(false) })
        // Measured once and fixed: a window sizing itself to the hosting view mid-layout threw from AppKit.
        host.sizingOptions = []
        let size = host.sizeThatFits(in: CGSize(width: 448, height: 2000))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(size)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        // A sheet on the window the change was made in, as macOS asks for anything blocking one task.
        let shell = NSApp.windows.first { $0.isVisible && $0.contentViewController is ShellSplitController }
        if let parent = shell {
            parent.beginSheet(window)
            parent.makeKeyAndOrderFront(nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    // The frame posts `{"cookie": "datadome=…; Domain=.soundcloud.com; …"}` to its parent once passed.
    private static func page(for captcha: URL) -> String {
        let source = captcha.absoluteString.replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;height:100%;background:transparent}iframe{border:0;width:100%;height:100%}</style>
        </head><body><iframe src="\(source)"></iframe><script>
        window.addEventListener('message', function (event) {
            if (String(event.origin).indexOf('captcha-delivery.com') === -1) return;
            var data = event.data;
            try { if (typeof data === 'string') data = JSON.parse(data); } catch (e) { return; }
            if (!data || !data.cookie) return;
            document.cookie = data.cookie;
            window.webkit.messageHandlers.captcha.postMessage('solved');
        });
        </script></body></html>
        """
    }

    private func finish(_ solved: Bool) {
        guard window != nil else { return }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "captcha")
        let window = window
        self.window = nil
        webView = nil
        window?.delegate = nil
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window?.close()
        }
        let resumed = waiting
        waiting.removeAll()
        resumed.forEach { $0.resume(returning: solved) }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in finish(true) }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in finish(false) }
    }
}

private struct CaptchaSheet: View {
    let webView: WKWebView
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.scOrange)
            VStack(spacing: 6) {
                Text("Quick Check").font(.title2.bold())
                Text("SoundCloud wants to be sure a person is making this change. Solve the puzzle below and "
                     + "Nimbus will save it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CaptchaFrame(webView: webView)
                .frame(width: 400, height: 460)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator)
                }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 448)
    }
}

private struct CaptchaFrame: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

#if DEBUG
#Preview("Captcha sheet") {
    let webView = WKWebView()
    webView.loadHTMLString("<body style='margin:0;background:#fff;font:14px -apple-system;display:grid;"
                           + "place-items:center;height:100vh'>DataDome puzzle</body>", baseURL: nil)
    return CaptchaSheet(webView: webView) {}
}
#endif
