import Foundation

nonisolated struct SCUser: Codable, Sendable, Identifiable, Hashable {
    struct Visuals: Codable, Sendable, Hashable {
        struct Visual: Codable, Sendable, Hashable {
            let visualUrl: String?
            enum CodingKeys: String, CodingKey { case visualUrl = "visual_url" }
        }
        let visuals: [Visual]?
    }

    let id: Int
    let username: String
    let avatarURL: String?
    let permalinkURL: String?
    let followersCount: Int?
    let followingsCount: Int?
    let trackCount: Int?
    let city: String?
    let countryCode: String?
    let description: String?
    let verified: Bool?
    let visuals: Visuals?

    var bannerURL: String? { visuals?.visuals?.first?.visualUrl }

    enum CodingKeys: String, CodingKey {
        case id, username, city, description, verified, visuals
        case avatarURL = "avatar_url"
        case permalinkURL = "permalink_url"
        case followersCount = "followers_count"
        case followingsCount = "followings_count"
        case trackCount = "track_count"
        case countryCode = "country_code"
    }
}

nonisolated struct SCTranscoding: Codable, Sendable {
    struct Format: Codable, Sendable {
        let `protocol`: String
        let mimeType: String

        enum CodingKeys: String, CodingKey {
            case `protocol`
            case mimeType = "mime_type"
        }
    }

    let url: String
    let preset: String
    let format: Format
    let quality: String

    var isHLS: Bool { format.protocol == "hls" }
    var isProgressive: Bool { format.protocol == "progressive" }
    var isAAC: Bool { preset.contains("aac") }
    var isMP3: Bool { preset.contains("mp3") }
    /// FairPlay SAMPLE-AES (cbcs). SoundCloud also offers `ctr-encrypted-hls` (cenc) for
    /// Widevine/PlayReady, but on Apple platforms we want the cbcs/FairPlay variant.
    var isFairPlay: Bool { format.protocol == "cbc-encrypted-hls" }
}

nonisolated struct SCMedia: Codable, Sendable {
    let transcodings: [SCTranscoding]
}

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
    let publisherMetadata: SCPublisherMetadata?
    let waveformURL: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, media, user, genre
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

    /// Relative age the way SoundCloud labels a like ("3 years ago"). api-v2 sends ISO-8601 for
    /// tracks but the older "yyyy/MM/dd HH:mm:ss Z" shape still turns up on some payloads.
    var ageLabel: String? {
        guard let createdAt, let date = Self.parseDate(createdAt) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func parseDate(_ raw: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
        return fallback.date(from: raw)
    }

    /// SoundCloud is track-centric; an album title is only present for released catalogue tracks.
    var album: String? { publisherMetadata?.albumTitle }

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

nonisolated struct SCStreamURL: Codable, Sendable {
    let url: String
    /// Present for encrypted streams; forwarded as the `license_token` to the FairPlay endpoint.
    let licenseAuthToken: String?
}

nonisolated struct SCMe: Codable, Sendable {
    let id: Int
    let username: String
}

/// One page of a `linked_partitioning` collection of liked tracks.
nonisolated struct SCTrackLikesPage: Codable, Sendable {
    struct Item: Codable, Sendable {
        let track: SCTrack
    }

    let collection: [Item]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }
}

/// A playlist (user-made or system mix). Its `tracks` arrive as `{id}` stubs — the full,
/// playable tracks are fetched in batches via `/tracks?ids=`.
nonisolated struct SCPlaylist: Decodable, Sendable, Identifiable, Hashable {
    /// User playlists use an integer id; system mixes use a URN string — keep it as a string.
    let id: String
    let title: String
    let artworkURL: String?
    let trackCount: Int
    let trackIDs: [Int]
    let user: SCUser?
    let description: String?
    let isAlbum: Bool
    let isSystem: Bool
    let duration: Int?

    /// Curated sets are all authored by "SoundCloud", which says nothing — show the size instead.
    var byline: String {
        guard let author = user?.username, author.lowercased() != "soundcloud" else {
            return "\(trackCount) tracks"
        }
        return author
    }

    private struct Stub: Decodable { let id: Int }

    enum CodingKeys: String, CodingKey {
        case id, title, tracks, urn, kind, user, description, duration
        case artworkURL = "artwork_url"
        case calculatedArtworkURL = "calculated_artwork_url"
        case trackCount = "track_count"
        case isAlbum = "is_album"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? c.decode(Int.self, forKey: .id) {
            id = String(intID)
        } else if let stringID = try? c.decode(String.self, forKey: .id) {
            id = stringID
        } else {
            id = try c.decode(String.self, forKey: .urn)
        }
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        artworkURL = try c.decodeIfPresent(String.self, forKey: .artworkURL)
            ?? c.decodeIfPresent(String.self, forKey: .calculatedArtworkURL)
        let stubs = try c.decodeIfPresent([Stub].self, forKey: .tracks) ?? []
        trackIDs = stubs.map(\.id)
        trackCount = try c.decodeIfPresent(Int.self, forKey: .trackCount) ?? stubs.count
        user = try? c.decodeIfPresent(SCUser.self, forKey: .user)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        isAlbum = (try? c.decodeIfPresent(Bool.self, forKey: .isAlbum)) ?? false
        let kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        isSystem = kind == "system-playlist" || Int(id) == nil
        duration = try? c.decodeIfPresent(Int.self, forKey: .duration)
    }
}

/// A shelf item: SoundCloud itself signals whether a shelf holds sets or people.
nonisolated enum SCSelectionItem: Decodable, Sendable, Identifiable {
    case playlist(SCPlaylist)
    case user(SCUser)

    var id: String {
        switch self {
        case .playlist(let p): "p\(p.id)"
        case .user(let u): "u\(u.id)"
        }
    }

    private enum KindKey: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: KindKey.self).decode(String.self, forKey: .kind)
        switch kind {
        case "playlist", "system-playlist": self = .playlist(try SCPlaylist(from: decoder))
        case "user": self = .user(try SCUser(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown selection kind \(kind)"))
        }
    }
}

/// One `/mixed-selections` shelf — this endpoint *is* soundcloud.com/discover: "More of what you
/// like", "Recently played", "Trending by genre", "Artists to watch out for", "Curated by SoundCloud".
nonisolated struct SCMixedSelection: Decodable, Sendable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let items: [SCSelectionItem]

    var playlists: [SCPlaylist] {
        items.compactMap { if case .playlist(let p) = $0 { p } else { nil } }
    }
    var users: [SCUser] {
        items.compactMap { if case .user(let u) = $0 { u } else { nil } }
    }
    var isPeopleShelf: Bool { !users.isEmpty && playlists.isEmpty }

    private enum CodingKeys: String, CodingKey { case urn, title, description, items }
    private struct Items: Decodable { let collection: [SCFailable<SCSelectionItem>] }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "For you"
        id = try c.decodeIfPresent(String.self, forKey: .urn) ?? title
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        items = (try c.decodeIfPresent(Items.self, forKey: .items))?.collection.compactMap(\.value) ?? []
    }
}

nonisolated struct SCMixedSelectionsPage: Decodable, Sendable {
    let collection: [SCMixedSelection]

    private enum CodingKeys: String, CodingKey { case collection }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode([SCFailable<SCMixedSelection>].self, forKey: .collection).compactMap(\.value)
    }
}

/// `/me/library/all` aggregates likes/reposts/playlists; we keep the playlist-shaped items.
nonisolated struct SCLibraryPage: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let playlist: SCPlaylist?
        let systemPlaylist: SCPlaylist?

        enum CodingKeys: String, CodingKey {
            case playlist
            case systemPlaylist = "system_playlist"
        }

        var asPlaylist: SCPlaylist? { playlist ?? systemPlaylist }
    }

    let collection: [Item]
}

/// A flat `linked_partitioning` page (e.g. a user's tracks, search/tracks).
nonisolated struct SCPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let collection: [Item]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }
}

/// Wraps a decode so one malformed element doesn't fail the whole collection.
nonisolated struct SCFailable<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// A universal-search result item, dispatched on the object's `kind`.
nonisolated enum SCSearchItem: Decodable, Sendable, Identifiable {
    case track(SCTrack)
    case user(SCUser)
    case playlist(SCPlaylist)

    var id: String {
        switch self {
        case .track(let t): "t\(t.id)"
        case .user(let u): "u\(u.id)"
        case .playlist(let p): "p\(p.id)"
        }
    }

    private enum KindKey: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: KindKey.self).decode(String.self, forKey: .kind)
        switch kind {
        case "track": self = .track(try SCTrack(from: decoder))
        case "user": self = .user(try SCUser(from: decoder))
        case "playlist", "playlist-like": self = .playlist(try SCPlaylist(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown kind \(kind)"))
        }
    }
}

/// One entry of the personalized `/stream` feed: a track or playlist that someone you follow
/// posted or reposted. Reposts carry the reposter so the UI can show "Reposted by …".
nonisolated struct SCStreamItem: Decodable, Sendable, Identifiable {
    enum Content: Sendable {
        case track(SCTrack)
        case playlist(SCPlaylist)
    }

    let content: Content
    let reposter: SCUser?
    let createdAt: String?

    var id: String {
        let base: String = switch content {
        case .track(let t): "t\(t.id)"
        case .playlist(let p): "p\(p.id)"
        }
        return "\(createdAt ?? "")-\(reposter?.id ?? 0)-\(base)"
    }

    private enum CodingKeys: String, CodingKey {
        case type, user, track, playlist
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        reposter = type.contains("repost") ? try c.decodeIfPresent(SCUser.self, forKey: .user) : nil
        if type.hasPrefix("track") {
            content = .track(try c.decode(SCTrack.self, forKey: .track))
        } else if type.hasPrefix("playlist") {
            content = .playlist(try c.decode(SCPlaylist.self, forKey: .playlist))
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown stream type \(type)"))
        }
    }
}

nonisolated struct SCStreamPage: Decodable, Sendable {
    let collection: [SCStreamItem]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextHref = try c.decodeIfPresent(String.self, forKey: .nextHref)
        collection = try c.decode([SCFailable<SCStreamItem>].self, forKey: .collection).compactMap(\.value)
    }
}

/// A `/search/tracks` page: bare track objects, decoded leniently.
nonisolated struct SCTrackSearchPage: Decodable, Sendable {
    let collection: [SCTrack]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextHref = try c.decodeIfPresent(String.self, forKey: .nextHref)
        collection = try c.decode([SCFailable<SCTrack>].self, forKey: .collection).compactMap(\.value)
    }
}

/// A `/charts` entry — the trending/top list wraps each track alongside a ranking score.
nonisolated struct SCChartPage: Decodable, Sendable {
    struct Item: Decodable, Sendable { let track: SCTrack }

    let collection: [SCTrack]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextHref = try c.decodeIfPresent(String.self, forKey: .nextHref)
        collection = try c.decode([SCFailable<Item>].self, forKey: .collection).compactMap { $0.value?.track }
    }
}

nonisolated struct SCSearchPage: Decodable, Sendable {
    let collection: [SCSearchItem]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextHref = try c.decodeIfPresent(String.self, forKey: .nextHref)
        collection = try c.decode([SCFailable<SCSearchItem>].self, forKey: .collection).compactMap(\.value)
    }
}
