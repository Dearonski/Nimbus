import Foundation

nonisolated struct SCTranscoding: Codable, Sendable {
    struct Format: Codable, Sendable {
        let `protocol`: String
    }

    let url: String
    let preset: String
    let format: Format
    let quality: String?

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

nonisolated struct SCStreamURL: Codable, Sendable {
    let url: String
    /// Present for encrypted streams; forwarded as the `license_token` to the FairPlay endpoint.
    let licenseAuthToken: String?
}
