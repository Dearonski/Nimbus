import SwiftUI

struct ProfileListView: View {
    let list: ProfileList
    let model: AppModel

    @Environment(\.metrics) private var metrics

    @State private var page: ProfileListModel?

    private var users: Pager<SCUser>? { page?.users }
    private var likes: Pager<SCLikeItem>? { page?.likes }

    private var isLoading: Bool { users?.isLoading == true || likes?.isLoading == true }
    private var hasRows: Bool { !(users?.items.isEmpty ?? true) || !(likes?.items.isEmpty ?? true) }

    private var likedTracks: [SCTrack] {
        (likes?.items ?? []).compactMap { if case .track(let track) = $0.content { track } else { nil } }
    }

    var body: some View {
        Group {
            switch list {
            case .likes:
                likeRows
            case .followers, .following:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        userGrid
                        if let users { ListPaging(users).footer }
                    }
                    .padding(.horizontal, gutter)
                    .padding(.vertical, 20)
                }
            }
        }
        .overlay {
            if !hasRows && page?.wasAsked == true && !isLoading {
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
        .task(id: list) {
            // SwiftUI can hand the same view instance a different route; the old list's rows must not stay.
            if page?.list != list, let key = PageModelKey(page: list) {
                page = model.pages.model(for: key) { ProfileListModel(list: list, api: model.api) }
            }
            await page?.load()
        }
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

    private var likeRows: some View {
        let queue = PlayQueue.exactly(likedTracks)
        return CardCollection(items: likes?.items ?? [],
                              heightKey: Self.heightVariant(of:),
                              layoutToken: metrics.listArtwork,
                              insets: NSEdgeInsets(top: 20, left: gutter, bottom: 20, right: gutter),
                              spacing: 20,
                              bottomReserve: PlayerPill.reservedHeight,
                              paging: likes.map { ListPaging($0) },
                              onPrefetch: { items in
                                  LikeCard.warm(items.compactMap {
                                      if case .track(let track) = $0.content { track } else { nil }
                                  })
                              }) { item in
            switch item.content {
            case .track(let track):
                LikeCard(track: track, player: model.player, queue: queue)
            case .playlist(let playlist):
                // A recycled cell would carry one set's spinner onto the next.
                SetCard(playlist: playlist, model: model).id(playlist.id)
            }
        }
        .ignoresSafeArea()
    }

    private static func heightVariant(of item: SCLikeItem) -> AnyHashable {
        switch item.content {
        case .track(let track): ["track", LikeCard.heightVariant(of: track)] as [AnyHashable]
        case .playlist(let playlist): SetCard.heightVariant(of: playlist)
        }
    }
}

/// One user's followers, followings or likes: the pager behind the list, kept so the list opens again as it was.
@Observable
final class ProfileListModel {
    let list: ProfileList
    let users: Pager<SCUser>?
    let likes: Pager<SCLikeItem>?
    /// Not set on cancellation: leaving before the first page left a false "no followers yet" behind.
    private(set) var wasAsked = false

    init(list: ProfileList, api: SoundCloudAPI) {
        self.list = list
        let id = list.user.id
        switch list {
        case .followers:
            users = Pager(first: { try await api.userFollowers(id: id, limit: 40).page },
                          next: { try await api.page(after: $0, as: SCPage<SCUser>.self).page })
            likes = nil
        case .following:
            users = Pager(first: { try await api.userFollowings(id: id, limit: 40).page },
                          next: { try await api.page(after: $0, as: SCPage<SCUser>.self).page })
            likes = nil
        case .likes:
            users = nil
            likes = Pager(first: { try await api.userLikes(id: id, limit: 24).page },
                          next: { try await api.page(after: $0, as: SCLikesPage.self).page })
        }
    }

    /// Only until a first page has come: one that failed is asked for again on the next opening.
    func load() async {
        if let users, !users.hasLoaded { await users.loadMore() }
        if let likes, !likes.hasLoaded { await likes.loadMore() }
        if !Task.isCancelled { wasAsked = true }
    }
}
