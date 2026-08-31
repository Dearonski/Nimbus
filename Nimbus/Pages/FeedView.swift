import SwiftUI

/// The social half of SoundCloud, given its own destination instead of being buried at the
/// bottom of Home: posts and reposts from the people you follow.
struct FeedView: View {
    let model: AppModel

    private var items: [SCStreamItem] { model.library.stream }
    private var tracks: [SCTrack] {
        items.compactMap { if case .track(let t) = $0.content { t } else { nil } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    StreamItemView(item: item, model: model, context: tracks)
                        .onAppear {
                            if item.id == items.last?.id {
                                Task { await model.library.loadMoreStream() }
                            }
                        }
                    if item.id != items.last?.id {
                        Divider().opacity(0.4).padding(.horizontal, 24)
                    }
                }
                if model.library.isLoadingStream {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .padding(.vertical, 20)
                }
            }
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
                        Button("Retry") { model.library.reloadStream() }
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
