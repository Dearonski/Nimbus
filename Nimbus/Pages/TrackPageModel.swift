import Foundation

/// Everything the track page shows besides the track itself. Each block loads on its own and stays
/// empty when it has nothing, so one dead endpoint never takes the page down with it.
@Observable
final class TrackPageModel {
    struct CommentState {
        var liked: Bool
        var likes: Int
    }

    let track: SCTrack
    private let api: SoundCloudAPI

    private(set) var commentPages: Pager<SCComment>

    private(set) var comments: [SCComment] {
        get { commentPages.items }
        set { commentPages.items = newValue }
    }
    var isLoadingComments: Bool { commentPages.isLoading }
    var commentsLoaded: Bool { commentPages.hasLoaded || commentPages.error != nil }

    var sort: SCCommentSort = .newest {
        didSet {
            guard sort != oldValue else { return }
            reloadComments()
        }
    }

    /// Replies live beside the list rather than inside `SCComment`: the gateway only says how many
    /// there are until they are asked for by comment urn.
    private(set) var replies: [String: [SCComment]] = [:]
    private(set) var expanded: Set<String> = []
    /// Optimistic like state, keyed by comment urn — the source list is not refetched on a tap.
    private var likeOverrides: [String: CommentState] = [:]

    private(set) var fans: SCTopFans?
    private(set) var related: [SCTrack] = []
    private(set) var albums: [SCPlaylist] = []
    private(set) var playlists: [SCPlaylist] = []
    /// The nested user on a track carries only a name and an avatar; the card needs counts.
    private(set) var author: SCUser?

    private(set) var postFailure: String?

    /// The comment field lives in the hero, but Reply is pressed down in the list — the draft and
    /// the focus request travel through here rather than through half a dozen bindings.
    var draft: String = ""
    private(set) var focusRequests = 0
    private(set) var reported: Set<String> = []

    init(track: SCTrack, api: SoundCloudAPI) {
        self.track = track
        self.api = api
        commentPages = Self.commentPages(for: track, sort: .newest, api: api)
    }

    func state(for comment: SCComment) -> CommentState {
        likeOverrides[comment.urn] ?? CommentState(liked: comment.likedByMe, likes: comment.likes)
    }

    func load() async {
        let pages = commentPages
        async let firstComments: Void = pages.loadMore()
        async let board = try? await api.topFans(trackURN: track.urn)
        async let relatedPage = try? await api.relatedTracks(id: track.id, limit: 6)
        async let albumPage = try? await api.trackAlbums(id: track.id)
        async let playlistPage = try? await api.trackPlaylists(id: track.id)
        async let fullAuthor = try? await api.user(id: track.user.id)

        await firstComments
        let fetchedFans = await board
        fans = (fetchedFans?.isEmpty ?? true) ? nil : fetchedFans
        related = await relatedPage?.collection ?? []
        albums = await albumPage?.collection ?? []
        playlists = await playlistPage?.collection ?? []
        author = await fullAuthor
    }

    func loadMoreComments() async {
        await commentPages.loadMore()
    }

    func toggleReplies(_ comment: SCComment) {
        if expanded.contains(comment.urn) {
            expanded.remove(comment.urn)
            return
        }
        expanded.insert(comment.urn)
        guard replies[comment.urn] == nil else { return }
        Task {
            let page = try? await api.commentReplies(trackURN: track.urn, commentURN: comment.urn)
            replies[comment.urn] = page?.comments ?? []
        }
    }

    /// SoundCloud has no reply mutation of its own: a reply is an ordinary comment that opens with
    /// the handle, and the gateway threads it under the original. Verified against a live thread —
    /// its reply body starts with "@kamilla-donchenko".
    func beginReply(to comment: SCComment) {
        let handle = comment.user.permalinkURL?.split(separator: "/").last.map(String.init)
            ?? comment.user.username
        draft = "@\(handle) "
        focusRequests += 1
    }

    func report(_ comment: SCComment) {
        reported.insert(comment.urn)
        Task {
            do {
                try await api.reportComment(commentURN: comment.urn)
            } catch {
                reported.remove(comment.urn)
            }
        }
    }

    func toggleLike(_ comment: SCComment) {
        let current = state(for: comment)
        let next = CommentState(liked: !current.liked, likes: max(0, current.likes + (current.liked ? -1 : 1)))
        likeOverrides[comment.urn] = next
        Task {
            do {
                try await api.setCommentLike(next.liked, commentURN: comment.urn, trackURN: track.urn)
            } catch {
                likeOverrides[comment.urn] = current
            }
        }
    }

    /// Posts at the given position and puts the comment straight into the list, the way the site
    /// does — refetching would drop it to wherever the sort puts it.
    func post(_ body: String, at trackTime: Int) async {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        postFailure = nil
        do {
            let comment = try await api.postComment(trackURN: track.urn, body: text, trackTime: trackTime)
            comments.insert(comment, at: 0)
        } catch let failure as SoundCloudAPI.GraphQLFailure {
            // The gateway's own words: a silent "couldn't post" hid a schema error for a while.
            postFailure = failure.messages.first ?? "Couldn't post the comment"
        } catch {
            postFailure = "Couldn't post the comment"
        }
    }

    func delete(_ comment: SCComment) {
        let index = comments.firstIndex { $0.urn == comment.urn }
        comments.removeAll { $0.urn == comment.urn }
        Task {
            do {
                try await api.deleteComment(commentURN: comment.urn)
            } catch {
                if let index { comments.insert(comment, at: min(index, comments.count)) }
            }
        }
    }

    // A fresh pager per sort, so a page still in flight for the old order lands nowhere.
    private func reloadComments() {
        let pages = Self.commentPages(for: track, sort: sort, api: api)
        commentPages = pages
        Task { await pages.loadMore() }
    }

    private static func commentPages(for track: SCTrack, sort: SCCommentSort,
                                     api: SoundCloudAPI) -> Pager<SCComment> {
        Pager(first: { try await api.trackComments(trackURN: track.urn, sort: sort).page },
              next: { try await api.trackComments(trackURN: track.urn, sort: sort, after: $0).page })
    }
}

#if DEBUG
extension TrackPageModel {
    func seedForPreview(comments: [SCComment] = [], fans: SCTopFans? = nil,
                        related: [SCTrack] = [], playlists: [SCPlaylist] = [], author: SCUser? = nil) {
        commentPages.seedForPreview(comments)
        self.fans = fans
        self.related = related
        self.playlists = playlists
        self.author = author
    }
}
#endif
