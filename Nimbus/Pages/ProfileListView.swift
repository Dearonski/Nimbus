import SwiftUI

/// The full version of a block in an artist's rail. Kept as one route so the rail's "View all"
/// controls all push the same destination type.
enum ProfileList: Hashable {
    case followers(SCUser)
    case following(SCUser)
    case likes(SCUser)

    var user: SCUser {
        switch self {
        case .followers(let user), .following(let user), .likes(let user): user
        }
    }

    var title: String {
        switch self {
        case .followers: "Followers"
        case .following: "Following"
        case .likes: "Likes"
        }
    }
}

struct ProfileListView: View {
    let list: ProfileList
    let model: AppModel

    @Environment(\.metrics) private var metrics

    @State private var users: [SCUser] = []
    @State private var likes: [SCLikeItem] = []
    @State private var nextHref: String?
    @State private var isLoading = false
    /// Which list the state belongs to, rather than a bare "loaded" flag: SwiftUI can hand the
    /// same view instance a different route, and a flag would leave the previous artist's rows.
    @State private var loadedList: ProfileList?

    private var likedTracks: [SCTrack] {
        likes.compactMap { if case .track(let track) = $0.content { track } else { nil } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                switch list {
                case .likes: likeRows
                case .followers, .following: userGrid
                }
                FeedFooter(isLoading: isLoading)
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 20)
        }
        .overlay {
            if users.isEmpty && likes.isEmpty && loadedList == list && !isLoading {
                ContentUnavailableView("Nothing here", systemImage: "person.2",
                                       description: Text("\(list.user.username) has no \(list.title.lowercased()) yet."))
            }
        }
        .navigationTitle(list.title)
        .navigationSubtitle(list.user.username)
        .task(id: list) { await load() }
    }

    @ViewBuilder
    private var userGrid: some View {
        let triggers = users.pagingTriggerIDs
        LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.shelfAvatar + 24), spacing: 20)],
                  spacing: 24) {
            ForEach(users) { user in
                ArtistCircle(artist: user)
                    .paginates(triggers.contains(user.id)) { await loadMore() }
            }
        }
    }

    @ViewBuilder
    private var likeRows: some View {
        let triggers = likes.pagingTriggerIDs
        ForEach(likes) { item in
            Group {
                switch item.content {
                case .track(let track):
                    LikeCard(track: track, player: model.player, queue: .exactly(likedTracks))
                case .playlist(let playlist):
                    SetCard(playlist: playlist, model: model)
                }
            }
            .paginates(triggers.contains(item.id)) { await loadMore() }
        }
    }

    private func load() async {
        guard loadedList != list else { return }
        users = []
        likes = []
        nextHref = nil
        isLoading = true
        defer {
            isLoading = false
            loadedList = list
        }
        switch list {
        case .followers(let user):
            let page = try? await model.api.userFollowers(id: user.id, limit: 40)
            users = page?.collection ?? []
            nextHref = page?.nextHref
        case .following(let user):
            let page = try? await model.api.userFollowings(id: user.id, limit: 40)
            users = page?.collection ?? []
            nextHref = page?.nextHref
        case .likes(let user):
            let page = try? await model.api.userLikes(id: user.id, limit: 24)
            likes = page?.collection ?? []
            nextHref = page?.nextHref
        }
    }

    private func loadMore() async {
        guard let href = nextHref, !isLoading else { return }
        nextHref = nil
        isLoading = true
        defer { isLoading = false }
        switch list {
        case .followers, .following:
            guard let page = try? await model.api.nextUserPage(href) else { return }
            users.appendNew(page.collection)
            nextHref = page.nextHref
        case .likes:
            guard let page = try? await model.api.nextLikesPage(href) else { return }
            likes.appendNew(page.collection)
            nextHref = page.nextHref
        }
    }
}
