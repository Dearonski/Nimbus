import SwiftUI

struct TrackTable: View {
    let tracks: [SCTrack]
    let player: PlayerEngine
    var isLoading = false
    var onReachEnd: (() async -> Void)?

    var body: some View {
        let triggers = tracks.pagingTriggerIDs
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(tracks) { track in
                    TrackRow(track: track, player: player, queueContext: tracks)
                        .paginates(triggers.contains(track.id), onReachEnd)
                }
                FeedFooter(isLoading: isLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct TrackList: View {
    let feed: TrackFeed
    let player: PlayerEngine

    var body: some View {
        TrackTable(
            tracks: feed.tracks, player: player, isLoading: feed.isLoading,
            onReachEnd: { await feed.loadMore() })
        .overlay {
            if let error = feed.error, feed.tracks.isEmpty {
                ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            }
        }
        .task { feed.loadInitialIfNeeded() }
    }
}
