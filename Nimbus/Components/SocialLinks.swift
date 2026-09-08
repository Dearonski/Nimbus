import SwiftUI

/// The links an artist listed on their profile. SF Symbols carries no brand marks, so every
/// network gets the closest system glyph — bundling traced logos would mean shipping eight
/// trademarks for a six-line block.
struct SocialLinks: View {
    let profiles: [SCWebProfile]

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(profiles) { profile in
                Button {
                    if let url = URL(string: profile.url) { openURL(url) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: Self.symbol(for: profile))
                            .font(.system(size: 13))
                            .frame(width: 16)
                        Text(Self.label(for: profile))
                            .font(.system(size: 13))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(profile.url)
            }
        }
    }

    /// The artist's own caption wins — it is what the site shows. Falls back to the network's
    /// proper name, and for `personal` to whatever the host says the link actually is.
    static func label(for profile: SCWebProfile) -> String {
        if let title = profile.title, !title.isEmpty { return title }
        if let name = names[profile.network] { return name }
        if let known = names[host(of: profile)] { return known }
        return host(of: profile).isEmpty ? profile.network.capitalized : host(of: profile)
    }

    static func symbol(for profile: SCWebProfile) -> String {
        symbols[profile.network] ?? symbols[host(of: profile)] ?? "globe"
    }

    private static func host(of profile: SCWebProfile) -> String {
        guard let host = URL(string: profile.url)?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static let names = [
        "vkontakte": "VK", "vk.com": "VK",
        "youtube": "YouTube", "youtube.com": "YouTube", "youtu.be": "YouTube",
        "instagram": "Instagram", "instagram.com": "Instagram",
        "spotify": "Spotify", "open.spotify.com": "Spotify",
        "soundcloud": "SoundCloud", "bandcamp": "Bandcamp", "bandcamp.com": "Bandcamp",
        "tumblr": "Tumblr", "songkick": "Songkick", "twitter": "X", "x.com": "X",
        "t.me": "Telegram", "telegram.me": "Telegram",
        "tiktok": "TikTok", "tiktok.com": "TikTok",
        "facebook": "Facebook", "facebook.com": "Facebook",
        "discord.gg": "Discord", "twitch.tv": "Twitch",
        "music.apple.com": "Apple Music", "linktr.ee": "Linktree",
    ]

    private static let symbols = [
        "instagram": "camera", "instagram.com": "camera",
        "youtube": "play.rectangle", "youtube.com": "play.rectangle", "youtu.be": "play.rectangle",
        "vkontakte": "v.circle", "vk.com": "v.circle",
        "spotify": "waveform", "open.spotify.com": "waveform",
        "soundcloud": "cloud", "bandcamp": "b.circle", "bandcamp.com": "b.circle",
        "twitter": "x.circle", "x.com": "x.circle",
        "facebook": "f.circle", "facebook.com": "f.circle",
        "t.me": "paperplane", "telegram.me": "paperplane",
        "tiktok": "music.note", "tiktok.com": "music.note",
        "discord.gg": "bubble.left.and.bubble.right", "twitch.tv": "gamecontroller",
        "music.apple.com": "applelogo", "linktr.ee": "link",
        "songkick": "calendar", "tumblr": "text.alignleft",
    ]
}

#if DEBUG
private func sampleProfile(_ network: String, _ title: String?, _ url: String) -> SCWebProfile {
    let json = """
    {"network":"\(network)","title":\(title.map { "\"\($0)\"" } ?? "null"),\
    "url":"\(url)","username":null}
    """
    return try! JSONDecoder().decode(SCWebProfile.self, from: Data(json.utf8))
}

#Preview("Social links") {
    SocialLinks(profiles: [
        sampleProfile("instagram", "insta", "https://www.instagram.com/budaog/"),
        sampleProfile("vkontakte", nil, "https://vk.com/ogbuda"),
        sampleProfile("youtube", nil, "https://www.youtube.com/c/OGBUDA/videos"),
        sampleProfile("personal", nil, "https://t.me/s/budaog"),
        sampleProfile("spotify", nil, "https://open.spotify.com/artist/6TsAG8"),
        sampleProfile("personal", "Merch", "https://shop.example.com"),
    ])
    .padding(24)
    .frame(width: 320)
    .tint(.scOrange)
}
#endif
