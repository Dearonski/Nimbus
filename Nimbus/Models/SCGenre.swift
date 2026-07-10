import Foundation

struct SCGenre: Identifiable, Hashable {
    let name: String
    let slug: String

    var id: String { slug }
    var urn: String { "soundcloud:genres:\(slug)" }

    static let all = SCGenre(name: "All genres", slug: "all-music")
    static let browse: [SCGenre] = [
        SCGenre(name: "Hip-hop & Rap", slug: "hiphoprap"),
        SCGenre(name: "Electronic", slug: "electronic"),
        SCGenre(name: "Dance & EDM", slug: "danceedm"),
        SCGenre(name: "Pop", slug: "pop"),
        SCGenre(name: "R&B & Soul", slug: "rbsoul"),
        SCGenre(name: "Rock", slug: "rock"),
        SCGenre(name: "Indie", slug: "indie"),
        SCGenre(name: "House", slug: "house"),
        SCGenre(name: "Deep House", slug: "deephouse"),
        SCGenre(name: "Techno", slug: "techno"),
        SCGenre(name: "Trance", slug: "trance"),
        SCGenre(name: "Drum & Bass", slug: "drumbass"),
        SCGenre(name: "Dubstep", slug: "dubstep"),
        SCGenre(name: "Trap", slug: "trap"),
        SCGenre(name: "Trip-hop", slug: "triphop"),
        SCGenre(name: "Ambient", slug: "ambient"),
        SCGenre(name: "Classical", slug: "classical"),
        SCGenre(name: "Jazz & Blues", slug: "jazzblues"),
        SCGenre(name: "Metal", slug: "metal"),
        SCGenre(name: "Country", slug: "country"),
        SCGenre(name: "Folk", slug: "folksingersongwriter"),
        SCGenre(name: "Latin", slug: "latin"),
        SCGenre(name: "Reggae", slug: "reggae"),
        SCGenre(name: "Reggaeton", slug: "reggaeton"),
        SCGenre(name: "Disco", slug: "disco"),
        SCGenre(name: "Piano", slug: "piano"),
        SCGenre(name: "Soundtrack", slug: "soundtrack"),
        SCGenre(name: "World", slug: "world"),
    ]
}
