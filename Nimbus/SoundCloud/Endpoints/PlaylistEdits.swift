import Foundation

// VERIFIED 05.11.2026 from the site's own requests: every change but delete is the playlist object
// under a `playlist` key, and the track list always goes whole — adding, removing and reordering alike.
private nonisolated struct PlaylistBody: Encodable {
    struct Fields: Encodable {
        var title: String?
        var description: String?
        var sharing: String?
        var tracks: [Int]?
        // Sent by the site on create only: a client-side id it reconciles the answer with.
        var resourceID: String?
        var resourceType: String?

        enum CodingKeys: String, CodingKey {
            case title, description, sharing, tracks
            case resourceID = "_resource_id"
            case resourceType = "_resource_type"
        }
    }

    let playlist: Fields

    var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension SCWrite {
    static func createPlaylist(title: String, isPrivate: Bool, trackIDs: [Int]) -> Self {
        let body = PlaylistBody(playlist: .init(title: title, sharing: isPrivate ? "private" : "public",
                                                tracks: trackIDs, resourceID: "f-1", resourceType: "playlist"))
        return .post("/playlists", json: body.json, verified: "2026-11-05")
    }

    static func setPlaylistTracks(_ id: Int, _ trackIDs: [Int]) -> Self {
        .put("/playlists/\(id)", json: PlaylistBody(playlist: .init(tracks: trackIDs)).json, verified: "2026-11-05")
    }

    // The site sends the whole object back with the new title; these are the fields Nimbus lets you change.
    static func editPlaylist(_ id: Int, title: String, description: String, isPrivate: Bool, trackIDs: [Int]) -> Self {
        let fields = PlaylistBody.Fields(title: title, description: description,
                                         sharing: isPrivate ? "private" : "public", tracks: trackIDs)
        return .put("/playlists/\(id)", json: PlaylistBody(playlist: fields).json, verified: "2026-11-05")
    }

    static func deletePlaylist(_ id: Int) -> Self {
        .delete("/playlists/\(id)", verified: "2026-11-05")
    }
}

extension SoundCloudAPI {
    func createPlaylist(title: String, isPrivate: Bool, trackIDs: [Int]) async throws -> SCPlaylist {
        try await send(.createPlaylist(title: title, isPrivate: isPrivate, trackIDs: trackIDs), as: SCPlaylist.self)
    }

    func setPlaylistTracks(id: Int, trackIDs: [Int]) async throws {
        try await send(.setPlaylistTracks(id, trackIDs))
    }

    func editPlaylist(id: Int, title: String, description: String, isPrivate: Bool, trackIDs: [Int]) async throws {
        try await send(.editPlaylist(id, title: title, description: description, isPrivate: isPrivate,
                                     trackIDs: trackIDs))
    }

    func deletePlaylist(id: Int) async throws {
        try await send(.deletePlaylist(id))
    }
}
