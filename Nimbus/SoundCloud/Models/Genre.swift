import Foundation

struct SCGenre: Identifiable, Hashable {
    let name: String
    let slug: String

    var id: String { slug }
    var urn: String { "soundcloud:genres:\(slug)" }

    // VERIFIED 06.11.2026: the site's "Trending by genre" slugs, the rest probed live; `/charts` serves stale tracks.
    static let charts: [SCGenre] = [
        SCGenre(name: "All genres", slug: "all-genres"),
        SCGenre(name: "Hip Hop", slug: "hip-hop"),
        SCGenre(name: "Trap", slug: "trap"),
        SCGenre(name: "Pop", slug: "pop"),
        SCGenre(name: "Electronic", slug: "electronic"),
        SCGenre(name: "R&B", slug: "r-n-b"),
        SCGenre(name: "Alternative Hip Hop", slug: "alternative-hip-hop"),
        SCGenre(name: "Indie", slug: "indie"),
        SCGenre(name: "House", slug: "house"),
        SCGenre(name: "Dubstep", slug: "dubstep"),
        SCGenre(name: "Rock", slug: "rock"),
        SCGenre(name: "Alternative Rock", slug: "alternative-rock"),
        SCGenre(name: "Folk", slug: "folk"),
        SCGenre(name: "Ambient", slug: "ambient"),
        SCGenre(name: "Hardcore", slug: "hardcore"),
        SCGenre(name: "Metal", slug: "metal"),
        SCGenre(name: "Reggae", slug: "reggae"),
        SCGenre(name: "Latin", slug: "latin"),
        SCGenre(name: "Dancehall", slug: "dancehall"),
        SCGenre(name: "Afrobeat", slug: "afrobeat"),
        SCGenre(name: "Techno", slug: "techno"),
        SCGenre(name: "EDM", slug: "edm"),
        SCGenre(name: "Trance", slug: "trance"),
        SCGenre(name: "Disco", slug: "disco"),
        SCGenre(name: "Soul", slug: "soul"),
        SCGenre(name: "Jazz", slug: "jazz"),
        SCGenre(name: "Blues", slug: "blues"),
        SCGenre(name: "Country", slug: "country"),
        SCGenre(name: "Classical", slug: "classical"),
        SCGenre(name: "Reggaeton", slug: "reggaeton"),
        SCGenre(name: "World", slug: "world"),
    ]

    var chartURN: String { "soundcloud:system-playlists:trending-by-genre:\(slug)" }
}
