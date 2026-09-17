import Foundation

extension SCWrite {
    /// Blocking is "muting" in api-v2: the web bundle's own route table spells `userBlockingsCreate`
    /// as PUT `me/mutings/{urn}`. VERIFIED 08.09.2026 — that path answers 401 unauthenticated, so it
    /// exists, while every guessed spelling (`/me/user_blocks/{id}`, `/users/{id}/block`) answers 404.
    static func blockUser(_ id: Int) -> Self {
        .put("/me/mutings/soundcloud:users:\(id)", verified: "2026-09-08")
    }

    static func unblockUser(_ id: Int) -> Self {
        .delete("/me/mutings/soundcloud:users:\(id)")
    }

    /// Path taken from SoundCloud's own web bundle, where the API map lists `myFollowingsCreate`
    /// and `myFollowingsDelete` against `me/followings/:id`. The verbs are minified there; PUT was
    /// ruled out by a live 404, leaving POST for create and DELETE for remove.
    static func followUser(_ id: Int) -> Self {
        .post("/me/followings/\(id)")
    }

    static func unfollowUser(_ id: Int) -> Self {
        .delete("/me/followings/\(id)")
    }

    static func likeTrack(_ userID: Int, trackID: Int) -> Self {
        .put("/users/\(userID)/track_likes/\(trackID)")
    }

    static func unlikeTrack(_ userID: Int, trackID: Int) -> Self {
        .delete("/users/\(userID)/track_likes/\(trackID)")
    }

    static func likePlaylist(_ userID: Int, playlistID: Int) -> Self {
        .put("/users/\(userID)/playlist_likes/\(playlistID)")
    }

    static func unlikePlaylist(_ userID: Int, playlistID: Int) -> Self {
        .delete("/users/\(userID)/playlist_likes/\(playlistID)")
    }

    static func repostTrack(_ trackID: Int) -> Self {
        .put("/me/track_reposts/\(trackID)")
    }

    static func unrepostTrack(_ trackID: Int) -> Self {
        .delete("/me/track_reposts/\(trackID)")
    }

    static func repostPlaylist(_ playlistID: Int) -> Self {
        .put("/me/playlist_reposts/\(playlistID)")
    }

    static func unrepostPlaylist(_ playlistID: Int) -> Self {
        .delete("/me/playlist_reposts/\(playlistID)")
    }
}

extension SoundCloudAPI {
    func blockUser(id: Int) async throws {
        try await send(.blockUser(id))
    }

    func unblockUser(id: Int) async throws {
        try await send(.unblockUser(id))
    }

    func followUser(id: Int) async throws {
        try await send(.followUser(id))
    }

    func unfollowUser(id: Int) async throws {
        try await send(.unfollowUser(id))
    }

    func likeTrack(userID: Int, trackID: Int) async throws {
        try await send(.likeTrack(userID, trackID: trackID))
    }

    func unlikeTrack(userID: Int, trackID: Int) async throws {
        try await send(.unlikeTrack(userID, trackID: trackID))
    }

    func likePlaylist(userID: Int, playlistID: Int) async throws {
        try await send(.likePlaylist(userID, playlistID: playlistID))
    }

    func unlikePlaylist(userID: Int, playlistID: Int) async throws {
        try await send(.unlikePlaylist(userID, playlistID: playlistID))
    }

    func repostTrack(trackID: Int) async throws {
        try await send(.repostTrack(trackID))
    }

    func unrepostTrack(trackID: Int) async throws {
        try await send(.unrepostTrack(trackID))
    }

    func repostPlaylist(playlistID: Int) async throws {
        try await send(.repostPlaylist(playlistID))
    }

    func unrepostPlaylist(playlistID: Int) async throws {
        try await send(.unrepostPlaylist(playlistID))
    }
}
