import SwiftUI

struct FollowingView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 20)], spacing: 24) {
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
