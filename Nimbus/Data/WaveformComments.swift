import Foundation
import Observation

/// Comments for a track that isn't the page you're on — a card in a list loads its own, because
/// only the track page has a `TrackPageModel`.
@MainActor
@Observable
final class WaveformCommentsLoader {
    private var comments: [SCComment] = []

    private static func key(_ urn: String, _ first: Int) -> NSString { "\(urn)#\(first)" as NSString }
    @ObservationIgnored private var loadedID: Int?
    @ObservationIgnored private var ownerID: Int?
    @ObservationIgnored private var first = 30

    /// Asked per track rather than read as state, for the reason `WaveformLoader.peaks(for:)` is.
    func comments(for track: SCTrack) -> [SCComment] {
        // Read before anything can return: a body that never touched it is not redrawn when the fetch lands.
        let loaded = comments
        if ownerID == track.id { return loaded }
        return Self.cache.object(forKey: Self.key(track.urn, first))?.comments ?? []
    }

    private final class Box {
        let comments: [SCComment]
        init(_ comments: [SCComment]) { self.comments = comments }
    }
    private static let cache = NSCache<NSString, Box>()

    /// Call from `.task`, so that scrolling a card away cancels the wait and the request with it.
    func load(_ track: SCTrack, api: SoundCloudAPI, first: Int = 30) async {
        guard loadedID != track.id else { return }
        loadedID = track.id
        self.first = first
        // The count rides along with the track, so a silent track costs no request at all.
        guard (track.commentCount ?? 0) > 0 else { return }
        // Cached comments are already on screen through `comments(for:)`.
        guard Self.cache.object(forKey: Self.key(track.urn, first)) == nil else { return }
        // A beat before asking — only when it really means a request. Flinging through a long feed
        // would otherwise fire one per card swept past, each answered after the card is gone.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else {
            loadedID = nil
            return
        }
        // Newest, not by position: TIMESTAMP starts at the beginning of the track and never gets
        // past it — measured 17.09.2026 on a track with 3197 comments, where the first 30 by
        // position (and the first 100) all sat on 0s, leaving the strip a single face. The newest
        // 30 spread across 73% of that track, the newest 60 across 95%.
        guard let page = try? await api.trackComments(trackURN: track.urn, sort: .newest, first: first) else {
            // Failed or cancelled: the next appearance asks again.
            if loadedID == track.id { loadedID = nil }
            return
        }
        Self.cache.setObject(Box(page.comments), forKey: Self.key(track.urn, first))
        guard loadedID == track.id else { return }
        ownerID = track.id
        comments = page.comments
    }

#if DEBUG
    static func seedCache(_ urn: String, _ comments: [SCComment], first: Int = 30) {
        cache.setObject(Box(comments), forKey: key(urn, first))
    }
#endif
}
