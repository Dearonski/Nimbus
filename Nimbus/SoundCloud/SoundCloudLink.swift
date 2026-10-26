import Foundation

/// A soundcloud.com address turned into the thing it names, so a link in a description opens a
/// page here instead of sending you to the browser.
nonisolated enum SoundCloudLink {
    private static let hosts: Set<String> = ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"]
    private static let shortHost = "on.soundcloud.com"

    static func isSoundCloud(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return hosts.contains(host) || host == shortHost
    }

    /// Text typed or pasted as a link, with or without its scheme.
    static func url(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" ") else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), isSoundCloud(url), url.path().count > 1 else { return nil }
        return url
    }

    static func resolve(_ url: URL, api: SoundCloudAPI) async -> SCSearchItem? {
        var target = url
        // Share links are redirects to the full address, which is what `/resolve` understands.
        if url.host()?.lowercased() == shortHost {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            guard let landed = try? await URLSession.shared.data(for: request).1.url else { return nil }
            target = landed
        }
        return try? await api.resolve(url: target)
    }
}
