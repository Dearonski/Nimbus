import SwiftUI

struct TrackTable: View {
    let tracks: [SCTrack]
    let player: PlayerEngine
    let queue: PlayQueue
    var isLoading = false
    var nextPageError: String?
    var onReachEnd: (() async -> Void)?

    var body: some View {
        CardCollection(items: tracks,
                       heightKey: { _ in 0 },
                       insets: NSEdgeInsets(top: 8, left: gutter, bottom: 8, right: gutter),
                       spacing: 2,
                       // A row keeps a hover flag, and a cell recycled under the pointer never hears it end.
                       resetsStateOnReuse: true,
                       bottomReserve: PlayerPill.reservedHeight,
                       footerHeight: isLoading || nextPageError != nil ? 54 : 0,
                       onNearEnd: { [onReachEnd] in Task { await onReachEnd?() } },
                       onPrefetch: { ArtworkPrefetcher.warm($0.map(\.coverURL), size: .thumb) }) { track in
            TrackRow(track: track, player: player, queue: queue)
        } footer: {
            FeedFooter(isLoading: isLoading, error: nextPageError, retry: onReachEnd)
        }
        .ignoresSafeArea()
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
        .task { feed.loadIfNeeded() }
    }
}
