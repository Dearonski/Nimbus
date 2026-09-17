import Foundation

nonisolated struct SCUser: Codable, Sendable, Identifiable, Hashable {
    struct Visuals: Codable, Sendable, Hashable {
        struct Visual: Codable, Sendable, Hashable {
            let visualUrl: String?
            enum CodingKeys: String, CodingKey { case visualUrl = "visual_url" }
        }
        let visuals: [Visual]?
    }

    struct Badges: Codable, Sendable, Hashable {
        let pro: Bool?
        let proUnlimited: Bool?

        enum CodingKeys: String, CodingKey {
            case pro
            case proUnlimited = "pro_unlimited"
        }
    }

    let id: Int
    let username: String
    let avatarURL: String?
    let permalinkURL: String?
    let followersCount: Int?
    let followingsCount: Int?
    let trackCount: Int?
    /// Liked tracks as SoundCloud counts them — the only source for a total, since the likes feed
    /// itself only ever knows the pages it has fetched.
    let likesCount: Int?
    let city: String?
    let countryCode: String?
    let description: String?
    let verified: Bool?
    let visuals: Visuals?
    let badges: Badges?

    var bannerURL: String? { visuals?.visuals?.first?.visualUrl }

    var isArtistPro: Bool { badges?.proUnlimited == true }

    enum CodingKeys: String, CodingKey {
        case id, username, city, description, verified, visuals, badges
        case avatarURL = "avatar_url"
        case permalinkURL = "permalink_url"
        case followersCount = "followers_count"
        case followingsCount = "followings_count"
        case trackCount = "track_count"
        case likesCount = "likes_count"
        case countryCode = "country_code"
    }

    /// The GraphQL gateway spells the same user in camelCase and identifies them by urn instead of
    /// a numeric id, so one decoder reads both shapes rather than the app carrying two user types.
    private enum GraphKeys: String, CodingKey {
        case urn, avatarUrl, permalinkUrl, followersCount, followingsCount, tracksCount, country
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let g = try decoder.container(keyedBy: GraphKeys.self)

        if let numeric = try c.decodeIfPresent(Int.self, forKey: .id) {
            id = numeric
        } else if let urn = try g.decodeIfPresent(String.self, forKey: .urn),
                  let tail = urn.split(separator: ":").last, let parsed = Int(tail) {
            id = parsed
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c,
                                                   debugDescription: "user has neither id nor urn")
        }
        username = try c.decode(String.self, forKey: .username)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? g.decodeIfPresent(String.self, forKey: .avatarUrl)
        permalinkURL = try c.decodeIfPresent(String.self, forKey: .permalinkURL)
            ?? g.decodeIfPresent(String.self, forKey: .permalinkUrl)
        followersCount = try c.decodeIfPresent(Int.self, forKey: .followersCount)
            ?? g.decodeIfPresent(Int.self, forKey: .followersCount)
        followingsCount = try c.decodeIfPresent(Int.self, forKey: .followingsCount)
            ?? g.decodeIfPresent(Int.self, forKey: .followingsCount)
        trackCount = try c.decodeIfPresent(Int.self, forKey: .trackCount)
            ?? g.decodeIfPresent(Int.self, forKey: .tracksCount)
        likesCount = try c.decodeIfPresent(Int.self, forKey: .likesCount)
        city = try c.decodeIfPresent(String.self, forKey: .city)
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
            ?? g.decodeIfPresent(String.self, forKey: .country)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified)
        visuals = try c.decodeIfPresent(Visuals.self, forKey: .visuals)
        badges = try c.decodeIfPresent(Badges.self, forKey: .badges)
    }
}

/// A link an artist put on their profile. `network` is SoundCloud's own slug — "instagram",
/// "vkontakte", "youtube" — and "personal" for anything it has no slug for, where only the url
/// says what the link actually is.
nonisolated struct SCWebProfile: Decodable, Sendable, Identifiable, Hashable {
    let network: String
    let title: String?
    let url: String
    let username: String?

    var id: String { url }
}
