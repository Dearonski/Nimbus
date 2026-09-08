import SwiftUI

/// The social half of SoundCloud, given its own destination instead of being buried at the
/// bottom of Home: posts and reposts from the people you follow.
struct FeedView: View {
    let model: AppModel

    var body: some View {
        let items = model.library.stream
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
                        .paginates(triggers.contains(item.id)) { await model.library.loadMoreStream() }
                }
                FeedFooter(isLoading: model.library.isLoadingStream, padding: 20)
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 12)
        }
        .overlay {
            if items.isEmpty && !model.library.isLoadingStream {
                // A failed load and a genuinely empty feed used to render the same empty state.
                if let error = model.library.streamError {
                    ContentUnavailableView {
                        Label("Couldn't load your feed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { model.library.reloadStream() }.glassButton()
                    }
                } else {
                    ContentUnavailableView("Nothing here yet", systemImage: "newspaper",
                        description: Text("Follow some artists and their posts show up here."))
                }
            }
        }
        .navigationTitle("Feed")
        .task { model.library.loadStreamIfNeeded() }
    }
}
