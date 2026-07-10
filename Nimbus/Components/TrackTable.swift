import SwiftUI

struct TrackTable: View {
    let tracks: [SCTrack]
    let player: PlayerEngine
    var isLoading = false
    var onReachEnd: () async -> Void = {}

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(tracks) { track in
                    TrackRow(track: track, player: player, queueContext: tracks)
                        .onAppear {
                            if track.id == tracks.last?.id { Task { await onReachEnd() } }
                        }
                }
                if isLoading {
                    ProgressView().controlSize(.small).padding(.vertical, 12)
                }
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
