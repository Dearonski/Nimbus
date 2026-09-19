import SwiftUI

/// The social half of SoundCloud, given its own destination instead of being buried at the
/// bottom of Home: posts and reposts from the people you follow.
struct FeedView: View {
    let model: AppModel

    @Environment(\.metrics) private var metrics

    var body: some View {
        let feed = model.library.stream
        let items = feed.items
        let tracks: [SCTrack] = items.compactMap {
            if case .track(let t) = $0.content { t } else { nil }
        }
        let queue = PlayQueue.exactly(tracks)
        // Cards, not rows: they carry their own edges, so the feed spaces them out and drops
        // the dividers that used to separate compact lines.
        return CardCollection(items: items,
                              heightKey: StreamItemView.heightVariant(of:),
                              layoutToken: metrics.listArtwork,
                              insets: NSEdgeInsets(top: 12, left: gutter, bottom: 12, right: gutter),
                              spacing: 20,
                              bottomReserve: PlayerPill.reservedHeight,
                              footerHeight: feed.isLoading || feed.nextPageError != nil ? 70 : 0,
                              onNearEnd: { Task { await feed.loadMore() } }) { item in
            StreamItemView(item: item, model: model, queue: queue)
        } footer: {
            FeedFooter(pager: feed, padding: 20)
        }
        .ignoresSafeArea()
        .overlay {
            if items.isEmpty && !feed.isLoading {
                // A failed load and a genuinely empty feed used to render the same empty state.
                if let error = feed.error {
                    LoadFailure(title: "Couldn't load your feed", message: error) {
                        model.library.reloadStream()
                    }
                } else if feed.hasLoaded {
                    ContentUnavailableView("Nothing here yet", systemImage: "newspaper",
                        description: Text("Follow some artists and their posts show up here."))
                }
            }
        }
        .task { model.library.loadStreamIfNeeded() }
    }
}
