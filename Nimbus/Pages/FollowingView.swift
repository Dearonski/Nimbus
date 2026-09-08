import SwiftUI

struct FollowingView: View {
    let model: AppModel

    @Environment(\.metrics) private var metrics

    private var isFirstLoad: Bool {
        model.library.following.isEmpty && model.library.isLoadingFollowing
    }

    var body: some View {
        ScrollView {
            if isFirstLoad {
                ArtistCirclesSkeleton().padding(24)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.shelfAvatar + 24), spacing: 20)], spacing: 24) {
                    ForEach(model.library.following) { artist in
                        ArtistCircle(artist: artist)
                    }
                }
                .padding(24)
            }
        }
        .overlay {
            if model.library.following.isEmpty && !isFirstLoad {
                if let error = model.library.followingError {
                    ContentUnavailableView {
                        Label("Couldn't load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { model.library.reloadFollowing() }.glassButton()
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
