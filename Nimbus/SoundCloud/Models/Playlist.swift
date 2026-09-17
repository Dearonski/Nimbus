import Foundation

/// A playlist (user-made or system mix). Its `tracks` arrive as `{id}` stubs — the full,
/// playable tracks are fetched in batches via `/tracks?ids=`.
nonisolated struct SCPlaylist: Decodable, Sendable, Identifiable, Hashable {
    /// User playlists use an integer id; system mixes use a URN string — keep it as a string.
    let id: String
    let title: String
    let artworkURL: String?
    let trackCount: Int
    let trackIDs: [Int]
    let firstTrackArtworkURL: String?
    /// The opening tracks api-v2 sends in full. Enough to list a set's first few without another
    /// request; the rest of `trackIDs` arrive as bare ids and have to be resolved.
    let hydratedTracks: [SCTrack]
    let user: SCUser?
    let description: String?
    let isAlbum: Bool
    let isSystem: Bool
    let duration: Int?
    let likesCount: Int?
    let repostsCount: Int?
    let createdAt: String?
    let lastModified: String?
    /// Only albums, EPs and singles carry one; a playlist has nothing here.
    let releaseDate: String?
    let genre: String?
    /// "album", "ep", "single", "compilation" — or empty on an ordinary playlist.
    let setType: String?
    let permalinkURL: String?
    /// Who a personalised mix was built for — the signed-in user, on every mix seen so far.
    let madeFor: SCUser?

    var kindLabel: String {
        switch setType {
        case "album": "Album"
        case "ep": "EP"
        case "single": "Single"
        case "compilation": "Compilation"
        default: isAlbum ? "Album" : isSystem ? "Mix" : "Playlist"
        }
    }

    var releaseLabel: String? {
        guard let releaseDate, let date = SCTrack.parseDate(releaseDate) else { return nil }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    /// Same relative label a track carries, so a set posted to a timeline reads like everything
    /// else in it.
    var ageLabel: String? {
        guard let createdAt, let date = SCTrack.parseDate(createdAt) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Curated sets are all authored by "SoundCloud", which says nothing — show the size instead.
    var byline: String {
        guard let author = user?.username, author.lowercased() != "soundcloud" else {
            return "\(trackCount) tracks"
        }
        return author
    }

    /// Null on about half of user playlists; the site falls back to the first track, then the owner.
    var coverURL: String? { artworkURL ?? firstTrackArtworkURL ?? user?.avatarURL }

    /// api-v2 hydrates only the first few nested tracks; the rest carry an id and nothing else.
    private struct Stub: Decodable {
        let id: Int
        let artworkURL: String?

        enum CodingKeys: String, CodingKey {
            case id
            case artworkURL = "artwork_url"
        }
    }

    /// The same array holds full tracks and bare stubs, so each element is tried on its own and
    /// the ones that are only an id fall out.
    private struct FailableTrack: Decodable {
        let track: SCTrack?
        init(from decoder: Decoder) throws { track = try? SCTrack(from: decoder) }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, tracks, urn, kind, user, description, duration
        case artworkURL = "artwork_url"
        case calculatedArtworkURL = "calculated_artwork_url"
        case trackCount = "track_count"
        case isAlbum = "is_album"
        case likesCount = "likes_count"
        case repostsCount = "reposts_count"
        case createdAt = "created_at"
        case lastModified = "last_modified"
        case releaseDate = "release_date"
        case genre
        case setType = "set_type"
        case permalinkURL = "permalink_url"
        case madeFor = "made_for"
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
        firstTrackArtworkURL = stubs.lazy.compactMap(\.artworkURL).first
        hydratedTracks = (try? c.decodeIfPresent([FailableTrack].self, forKey: .tracks))?
            .compactMap(\.track) ?? []
        trackCount = try c.decodeIfPresent(Int.self, forKey: .trackCount) ?? stubs.count
        user = try? c.decodeIfPresent(SCUser.self, forKey: .user)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        isAlbum = (try? c.decodeIfPresent(Bool.self, forKey: .isAlbum)) ?? false
        let kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        isSystem = kind == "system-playlist" || Int(id) == nil
        duration = try? c.decodeIfPresent(Int.self, forKey: .duration)
        likesCount = try? c.decodeIfPresent(Int.self, forKey: .likesCount)
        repostsCount = try? c.decodeIfPresent(Int.self, forKey: .repostsCount)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        lastModified = try? c.decodeIfPresent(String.self, forKey: .lastModified)
        releaseDate = try? c.decodeIfPresent(String.self, forKey: .releaseDate)
        genre = try? c.decodeIfPresent(String.self, forKey: .genre)
        setType = try? c.decodeIfPresent(String.self, forKey: .setType)
        permalinkURL = try? c.decodeIfPresent(String.self, forKey: .permalinkURL)
        madeFor = try? c.decodeIfPresent(SCUser.self, forKey: .madeFor)
    }
}
