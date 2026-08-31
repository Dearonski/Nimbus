import SwiftUI

struct FollowingView: View {
    let model: AppModel

    @Environment(\.metrics) private var metrics

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.shelfAvatar + 24), spacing: 20)], spacing: 24) {
                ForEach(model.library.following) { artist in
                    ArtistCircle(artist: artist)
                }
            }
            .padding(24)
        }
        .overlay {
            if model.library.following.isEmpty {
                if model.library.isLoadingFollowing {
                    ProgressView().controlSize(.small)
                } else if let error = model.library.followingError {
                    ContentUnavailableView {
                        Label("Couldn't load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { model.library.reloadFollowing() }
                    }
                } else {
                    ContentUnavailableView("Not following anyone", systemImage: "person.2",
                        description: Text("Artists you follow appear here."))
                }
            }
        }
        .navigationTitle("Following")
        .task { model.library.loadFollowingIfNeeded() }
    }
}
