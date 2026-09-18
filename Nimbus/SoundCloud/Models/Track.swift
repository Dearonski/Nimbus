import Foundation

nonisolated struct SCPublisherMetadata: Codable, Sendable {
    let albumTitle: String?
    /// Comma-separated when a track has several credited artists ("VIENCA, MPH").
    let artist: String?

    enum CodingKeys: String, CodingKey {
        case artist
        case albumTitle = "album_title"
    }
}

nonisolated struct SCTrack: Codable, Sendable, Identifiable, Hashable {
    static func == (lhs: SCTrack, rhs: SCTrack) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id: Int
    let title: String
    let duration: Int
    let permalinkURL: String
    let artworkURL: String?
    let user: SCUser
    let media: SCMedia
    let trackAuthorization: String
    let playbackCount: Int?
    let likesCount: Int?
    let commentCount: Int?
    let repostsCount: Int?
    let genre: String?
    let description: String?
    /// Space separated, with multi-word tags in quotes — SoundCloud's own format.
    let tagList: String?
    let publisherMetadata: SCPublisherMetadata?
    let waveformURL: String?
    let createdAt: String?
    let policy: String?
    let monetizationModel: String?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, media, user, genre, description, policy
        case monetizationModel = "monetization_model"
        case tagList = "tag_list"
        case permalinkURL = "permalink_url"
        case artworkURL = "artwork_url"
        case trackAuthorization = "track_authorization"
        case playbackCount = "playback_count"
        case likesCount = "likes_count"
        case commentCount = "comment_count"
        case repostsCount = "reposts_count"
        case publisherMetadata = "publisher_metadata"
        case waveformURL = "waveform_url"
        case createdAt = "created_at"
    }

    /// SoundCloud packs tags into one string, quoting the ones with spaces: `"Deep House" trap`.
    var tags: [String] {
        guard let tagList, !tagList.isEmpty else { return [] }
        var tags: [String] = []
        var current = ""
        var quoted = false
        for character in tagList {
            switch character {
            case "\"": quoted.toggle()
            case " " where !quoted:
                if !current.isEmpty { tags.append(current); current = "" }
            default: current.append(character)
            }
        }
        if !current.isEmpty { tags.append(current) }
        return tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
    }

    /// Relative age the way SoundCloud labels a like ("3 years ago"). api-v2 sends ISO-8601 for
    /// tracks but the older "yyyy/MM/dd HH:mm:ss Z" shape still turns up on some payloads.
    var ageLabel: String? {
        guard let createdAt, let date = Self.parseDate(createdAt) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Three shapes reach us: api-v2's own `2026/03/13 12:06:10 +0000`, plain ISO, and the ISO with
    /// milliseconds the GraphQL gateway sends (`2026-03-13T12:06:10.000Z`) — which the default
    /// ISO8601 formatter rejects outright, so every comment came back undated.
    static func parseDate(_ raw: String) -> Date? {
        if let date = isoFormatter.date(from: raw) { return date }
        if let date = isoWithMillisecondsFormatter.date(from: raw) { return date }
        return apiV2Formatter.date(from: raw)
    }

    // Date formatters have been safe to read from several threads since macOS 10.9; kept around
    // because `ageLabel` re-parses on every redraw of a comment list.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    nonisolated(unsafe) private static let isoWithMillisecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let apiV2Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
        return formatter
    }()

    /// SoundCloud is track-centric; an album title is only present for released catalogue tracks.
    var album: String? { publisherMetadata?.albumTitle }

    /// `artwork_url` is null whenever the uploader never set one, and the site falls back to their
    /// avatar rather than showing a blank. Display sites want this, not `artworkURL`.
    var coverURL: String? { artworkURL ?? user.avatarURL }

    /// Credited artists. The uploader's name is the canonical single-artist label — publisher
    /// metadata is only trusted when it actually lists several, since for solo tracks it carries
    /// noisy variants ("H U U E", "twinnjrr! (@fcktwinnjrr)").
    var artistNames: [String] {
        guard let raw = publisherMetadata?.artist?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return [user.username] }
        let names = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return names.count > 1 ? names : [user.username]
    }

    var artistLine: String { artistNames.joined(separator: ", ") }

    /// Unencrypted AAC over HLS (160 → 96) — played via HLSResourceLoader, no DRM needed.
    var bestHLSAAC: SCTranscoding? {
        let aac = media.transcodings.filter { $0.isHLS && $0.isAAC }
        return aac.first { $0.preset.contains("160") } ?? aac.first
    }

    /// FairPlay-encrypted AAC (cbcs, 160 → 96) — played via AVContentKeySession.
    var bestFairPlayAAC: SCTranscoding? {
        let enc = media.transcodings.filter { $0.isFairPlay && $0.isAAC }
        return enc.first { $0.preset.contains("160") } ?? enc.first
    }

    /// Direct progressive MP3 file — simple fallback, played straight through AVPlayer.
    var bestProgressive: SCTranscoding? {
        media.transcodings.first { $0.isProgressive }
    }

    /// Unencrypted MP3 over HLS — last-resort fallback, played via HLSResourceLoader.
    var bestHLSMP3: SCTranscoding? {
        media.transcodings.first { $0.isHLS && $0.isMP3 }
    }
}
