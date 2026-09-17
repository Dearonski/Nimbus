import SwiftUI

struct TrackTable: View {
    let tracks: [SCTrack]
    let player: PlayerEngine
    let queue: PlayQueue
    var isLoading = false
    var nextPageError: String?
    var onReachEnd: (() async -> Void)?

    var body: some View {
        let triggers = tracks.pagingTriggerIDs
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(tracks) { track in
                    TrackRow(track: track, player: player, queue: queue)
                        .paginates(triggers.contains(track.id), onReachEnd)
                }
                FeedFooter(isLoading: isLoading, error: nextPageError, retry: onReachEnd)
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 8)
        }
    }
}

struct TrackList: View {
    let feed: TrackFeed
    let player: PlayerEngine

    var body: some View {
        TrackTable(
            tracks: feed.tracks, player: player, queue: feed.playQueue(feed.tracks),
            isLoading: feed.isLoading, nextPageError: feed.nextPageError,
            onReachEnd: { await feed.loadMore() })
        .overlay {
            if let error = feed.error, feed.tracks.isEmpty, !feed.isLoading {
                LoadFailure(message: error) { Task { await feed.loadMore() } }
            }
        }
        .task { feed.loadInitialIfNeeded() }
    }
}
