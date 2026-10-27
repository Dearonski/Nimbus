import SwiftUI

struct FollowingView: View {
    let model: AppModel

    @Environment(\.metrics) private var metrics

    private var phase: ListPhase {
        ListPhase(model.library.followingList, isEmpty: model.library.following.isEmpty)
    }

    var body: some View {
        ScrollView {
            if phase == .loading {
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
        .listStatus(phase, retry: { model.library.reloadFollowing() }) {
            ContentUnavailableView("Not following anyone", systemImage: "person.2",
                description: Text("Artists you follow appear here."))
        }
        .task { model.library.loadFollowingIfNeeded() }
    }
}
