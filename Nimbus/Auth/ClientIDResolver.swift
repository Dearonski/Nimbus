import Foundation

/// Scrapes the rotating 32-char api-v2 client_id out of SoundCloud's web asset bundles.
/// Technique mirrors yt-dlp/extractor/soundcloud.py; re-scrape whenever the API returns 401/403.
actor ClientIDResolver {
    private var cached: String?

    private let scriptRegex = try! NSRegularExpression(
        pattern: #"<script[^>]+src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)""#)
    private let clientIDRegex = try! NSRegularExpression(
        pattern: #"client_id\s*[:=]\s*"([0-9a-zA-Z]{32})""#)

    func clientID(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cached { return cached }

        let (homeData, _) = try await URLSession.shared.data(from: URL(string: "https://soundcloud.com/")!)
        let home = String(decoding: homeData, as: UTF8.self)

        // Newest bundle carries the id — walk scripts last-to-first.
        for scriptURL in scriptURLs(in: home).reversed() {
            let (jsData, _) = try await URLSession.shared.data(from: scriptURL)
            let js = String(decoding: jsData, as: UTF8.self)
            if let id = firstMatch(clientIDRegex, in: js) {
                cached = id
                return id
            }
        }
        throw SCError.clientIDNotFound
    }

    func invalidate() { cached = nil }

    private func scriptURLs(in html: String) -> [URL] {
        let range = NSRange(html.startIndex..., in: html)
        return scriptRegex.matches(in: html, range: range).compactMap {
            Range($0.range(at: 1), in: html).flatMap { URL(string: String(html[$0])) }
        }
    }

    private func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
