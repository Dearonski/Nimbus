import Foundation

/// Scrapes the rotating 32-char api-v2 client_id out of SoundCloud's web asset bundles.
/// Technique mirrors yt-dlp/extractor/soundcloud.py; re-scrape whenever the API returns 401/403.
actor ClientIDResolver {
    private static let storedKey = "soundcloud.clientID"
    // Kept across launches: scraping it again held every first request back about 3 s, and a refusal still rotates it.
    private var cached: String? = UserDefaults.standard.string(forKey: storedKey)
    // A scrape walks the homepage and every bundle; a burst of refusals shares one instead of each starting its own.
    private var scraping: Task<String, Error>?

    private static let scriptRegex = try! NSRegularExpression(
        pattern: #"<script[^>]+src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)""#)
    private static let clientIDRegex = try! NSRegularExpression(
        pattern: #"client_id\s*[:=]\s*"([0-9a-zA-Z]{32})""#)

    func clientID() async throws -> String {
        if let cached { return cached }
        return try await scrape()
    }

    /// A fresh id after `stale` was refused; one someone else already fetched is taken as it is.
    func clientID(replacing stale: String) async throws -> String {
        if let cached, cached != stale { return cached }
        cached = nil
        return try await scrape()
    }

    private func scrape() async throws -> String {
        if let scraping { return try await scraping.value }
        let task = Task { try await Self.fetch() }
        scraping = task
        defer { scraping = nil }
        let id = try await task.value
        cached = id
        UserDefaults.standard.set(id, forKey: Self.storedKey)
        return id
    }

    private static func fetch() async throws -> String {
        let (homeData, _) = try await URLSession.shared.data(from: URL(string: "https://soundcloud.com/")!)
        let home = String(decoding: homeData, as: UTF8.self)

        // Newest bundle carries the id — walk scripts last-to-first.
        for scriptURL in scriptURLs(in: home).reversed() {
            let (jsData, _) = try await URLSession.shared.data(from: scriptURL)
            let js = String(decoding: jsData, as: UTF8.self)
            if let id = firstMatch(clientIDRegex, in: js) { return id }
        }
        throw SCError.clientIDNotFound
    }

    private static func scriptURLs(in html: String) -> [URL] {
        let range = NSRange(html.startIndex..., in: html)
        return scriptRegex.matches(in: html, range: range).compactMap {
            Range($0.range(at: 1), in: html).flatMap { URL(string: String(html[$0])) }
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
