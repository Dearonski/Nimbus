import SwiftUI

struct ProfileListView: View {
    let list: ProfileList
    let model: AppModel

    @Environment(\.metrics) private var metrics

    @State private var users: Pager<SCUser>?
    @State private var likes: Pager<SCLikeItem>?
    /// Which list the state belongs to, rather than a bare "loaded" flag: SwiftUI can hand the
    /// same view instance a different route, and a flag would leave the previous artist's rows.
    @State private var loadedList: ProfileList?

    private var isLoading: Bool { users?.isLoading == true || likes?.isLoading == true }
    private var hasRows: Bool { !(users?.items.isEmpty ?? true) || !(likes?.items.isEmpty ?? true) }

    private var likedTracks: [SCTrack] {
        (likes?.items ?? []).compactMap { if case .track(let track) = $0.content { track } else { nil } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                switch list {
                case .likes: likeRows
                case .followers, .following: userGrid
                }
                if let likes {
                    FeedFooter(pager: likes)
                } else if let users {
                    FeedFooter(pager: users)
                }
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 20)
        }
        .overlay {
            if !hasRows && loadedList == list && !isLoading {
                if let error = users?.firstPageError ?? likes?.firstPageError {
                    LoadFailure(message: error) {
                        Task { await users?.loadMore(); await likes?.loadMore() }
                    }
                } else {
                    ContentUnavailableView("Nothing here", systemImage: "person.2",
                                           description: Text("\(list.user.username) has no \(list.title.lowercased()) yet."))
                }
            }
        }
        .navigationTitle(list.title)
        .navigationSubtitle(list.user.username)
        .task(id: list) { await load() }
    }

    @ViewBuilder
    private var userGrid: some View {
        let rows = users?.items ?? []
        let triggers = rows.pagingTriggerIDs
        LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.shelfAvatar + 24), spacing: 20)],
                  spacing: 24) {
            ForEach(rows) { user in
                ArtistCircle(artist: user)
                    .paginates(triggers.contains(user.id)) { await users?.loadMore() }
            }
        }
    }

    @ViewBuilder
    private var likeRows: some View {
        let rows = likes?.items ?? []
        let triggers = rows.pagingTriggerIDs
        ForEach(rows) { item in
            Group {
                switch item.content {
                case .track(let track):
                    LikeCard(track: track, player: model.player, queue: .exactly(likedTracks))
                case .playlist(let playlist):
                    SetCard(playlist: playlist, model: model)
                }
            }
            .paginates(triggers.contains(item.id)) { await likes?.loadMore() }
        }
    }

    private func load() async {
        guard loadedList != list else { return }
        defer { loadedList = list }
        let api = model.api
        switch list {
        case .followers(let user):
            likes = nil
            let pages = Pager<SCUser>(
                first: { try await api.userFollowers(id: user.id, limit: 40).page },
                next: { try await api.nextUserPage($0).page })
            users = pages
            await pages.loadMore()
        case .following(let user):
            likes = nil
            let pages = Pager<SCUser>(
                first: { try await api.userFollowings(id: user.id, limit: 40).page },
                next: { try await api.nextUserPage($0).page })
            users = pages
            await pages.loadMore()
        case .likes(let user):
            users = nil
            let pages = Pager<SCLikeItem>(
                first: { try await api.userLikes(id: user.id, limit: 24).page },
                next: { try await api.nextLikesPage($0).page })
            likes = pages
            await pages.loadMore()
        }
    }
}
