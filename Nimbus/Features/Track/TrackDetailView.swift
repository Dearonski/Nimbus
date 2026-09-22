import SwiftUI

struct TrackDetailView: View {
    let track: SCTrack
    let model: AppModel

    @Environment(\.metrics) private var metrics
    @Environment(PageRoom.self) private var room: PageRoom?

    @State private var page: TrackPageModel?
    @Environment(\.onTitleCollapse) private var onTitleCollapse

    /// Shared with the hero, whose artwork lines up with this column exactly, the way it does on
    /// the site — both are 336 there, sitting on the same right edge.
    static let railMinimum: CGFloat = 1000
    static let railWidth: CGFloat = 336

    private var showsRail: Bool { Self.showsRail(in: room, usable: metrics.usable) }

    /// One answer for both pages and both heroes, so the artwork and the column under it agree.
    static func showsRail(in room: PageRoom?, usable: CGFloat) -> Bool {
        room?.fitsRail(railWidth, spacing: 28 + ContentMetrics.heroInset, minimum: railMinimum)
            ?? (usable >= railMinimum)
    }

    var body: some View {
        ZStack {
            if let page { list(page) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: track.id) {
            // A kept page runs this again every time it is shown; a new model threw away what it had.
            guard page?.track.id != track.id else { return }
            let pageModel = TrackPageModel(track: track, api: model.api)
            page = pageModel
            await pageModel.load()
        }
    }

    private enum Entry: Identifiable {
        case comment(SCComment)
        case note
        case failure(String)

        var id: AnyHashable {
            switch self {
            case .comment(let comment): comment.urn
            case .note: "note"
            case .failure: "failure"
            }
        }
    }

    private func entries(_ page: TrackPageModel) -> [Entry] {
        if let error = page.commentPages.firstPageError, !page.isLoadingComments { return [.failure(error)] }
        if page.comments.isEmpty, page.commentPages.hasLoaded { return [.note] }
        return page.comments.map(Entry.comment)
    }

    /// The rail scrolls with the page, unlike the artist's: here the column is long and the
    /// comments are what you came to read.
    private func list(_ page: TrackPageModel) -> some View {
        let pages = page.commentPages
        return CardCollection(items: entries(page),
                              heightKey: \.id,
                              insets: NSEdgeInsets(top: 22, left: gutter + ContentMetrics.heroInset, bottom: 8,
                                                   right: gutter + ContentMetrics.heroInset),
                              spacing: 0,
                              bottomReserve: PlayerPill.reservedHeight,
                              footerHeight: pages.isLoading || pages.nextPageError != nil ? 54 : 0,
                              header: AnyView(TrackHero(track: track, model: model, page: page)
                                  .padding(.horizontal, gutter)
                                  .padding(.top, 10)),
                              lead: AnyView(VStack(alignment: .leading, spacing: 20) {
                                  details
                                  TrackCommentsHeader(page: page)
                              }),
                              side: CardCollectionSide(width: Self.railWidth, spacing: 28, isBeside: showsRail,
                                                       content: AnyView(TrackRail(page: page, model: model))),
                              selfSizing: true,
                              estimatedHeight: 76,
                              titleEdge: PlaylistList.titleEdge,
                              onTitleCollapse: { onTitleCollapse($0) },
                              onNearEnd: { Task { await page.loadMoreComments() } }) { entry in
            switch entry {
            case .comment(let comment):
                CommentRow(comment: comment, page: page, model: model)
            case .note:
                Text("No comments yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            case .failure(let error):
                LoadFailure(title: "Couldn't load comments", message: error) {
                    Task { await page.loadMoreComments() }
                }
                .padding(.vertical, 10)
            }
        } footer: {
            FeedFooter(pager: pages)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var details: some View {
        let text = track.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty || !track.tags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !text.isEmpty {
                    ArtistBio(text: text, animatesItself: false)
                        .frame(maxWidth: 680, alignment: .leading)
                }
                if !track.tags.isEmpty {
                    FlowTags(tags: track.tags)
                }
            }
        }
    }
}

/// Genre tags under the description. Wraps rather than scrolls: a track with a dozen tags should
/// grow the block, not hide half of them off the edge.
private struct FlowTags: View {
    let tags: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(tags)
            VStack(alignment: .leading, spacing: 6) {
                row(Array(tags.prefix(tags.count / 2)))
                row(Array(tags.dropFirst(tags.count / 2)))
            }
        }
    }

    private func row(_ items: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { tag in
                Text("# \(tag)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.06), in: Capsule())
            }
        }
    }
}
