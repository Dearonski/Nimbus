import SwiftUI

/// The social half of SoundCloud, given its own destination instead of being buried at the
/// bottom of Home: posts and reposts from the people you follow.
struct FeedView: View {
    let model: AppModel

    var body: some View {
        let feed = model.library.stream
        let items = feed.items
        let tracks: [SCTrack] = items.compactMap {
            if case .track(let t) = $0.content { t } else { nil }
        }
        let triggers = items.pagingTriggerIDs
        return ScrollView {
            // Cards, not rows: they carry their own edges, so the feed spaces them out and drops
            // the dividers that used to separate compact lines.
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(items) { item in
                    StreamItemView(item: item, model: model, queue: .exactly(tracks))
                        .paginates(triggers.contains(item.id)) { await feed.loadMore() }
                }
                FeedFooter(pager: feed, padding: 20)
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 12)
        }
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
        .navigationTitle("Feed")
        .task { model.library.loadStreamIfNeeded() }
    }
}
