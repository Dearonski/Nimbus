import SwiftUI

struct TrackTable: View {
    let tracks: [SCTrack]
    let player: PlayerEngine
    let queue: PlayQueue
    var paging: ListPaging?

    var body: some View {
        CardCollection(items: tracks,
                       rows: .measured(by: { _ in 0 }),
                       insets: NSEdgeInsets(top: 8, left: gutter, bottom: 8, right: gutter),
                       spacing: 2,
                       bottomReserve: PlayerPill.reservedHeight,
                       paging: paging,
                       onPrefetch: { ArtworkPrefetcher.warm($0.map(\.coverURL), size: .thumb) }) { track in
            TrackRow(track: track, player: player, queue: queue)
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
            paging: ListPaging(feed))
        .listStatus(ListPhase(feed, isEmpty: feed.tracks.isEmpty), retry: { Task { await feed.loadMore() } })
        .task { feed.loadIfNeeded() }
    }
}
