import Foundation

nonisolated struct SCMe: Codable, Sendable {
    let id: Int
    let username: String
}

/// A signed upload slot from `/presign/visuals`: a storage URL and the form fields that have to go
/// in front of the file. VERIFIED 13.09.2026 — the URL is the soundcloud-images S3 bucket.
nonisolated struct SCVisualTicket: Decodable, Sendable {
    let url: String
    let fields: [String: String]
}

/// What the edit form starts from, as `/me` spells it.
nonisolated struct SCEditableProfile: Decodable, Sendable {
    let username: String
    let permalink: String?
    let firstName: String?
    let lastName: String?
    let city: String?
    let countryCode: String?
    let description: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case username, permalink, city, description
        case firstName = "first_name"
        case lastName = "last_name"
        case countryCode = "country_code"
        case avatarURL = "avatar_url"
    }
}
