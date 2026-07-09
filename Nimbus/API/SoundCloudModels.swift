import Foundation

nonisolated struct SCUser: Codable, Sendable {
    let username: String
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

nonisolated struct SCTrack: Codable, Sendable, Identifiable {
    let id: Int
    let title: String
    let duration: Int
    let permalinkURL: String
    let artworkURL: String?
    let user: SCUser
    let media: SCMedia
    let trackAuthorization: String

    enum CodingKeys: String, CodingKey {
        case id, title, duration, media, user
        case permalinkURL = "permalink_url"
        case artworkURL = "artwork_url"
        case trackAuthorization = "track_authorization"
    }

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
