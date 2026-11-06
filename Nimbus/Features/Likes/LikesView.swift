import SwiftUI

enum LibraryLayout: String, CaseIterable, Identifiable {
    case list, grid

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        }
    }
}

enum LikesSort: String, CaseIterable, Identifiable {
    case recent = "Recently added"
    case title = "Title"
    case artist = "Artist"
    case longest = "Longest"
    case plays = "Most played"

    var id: String { rawValue }
}

// Shared by the page and the window's toolbar, which holds the controls.
@MainActor
@Observable
final class LikesControls {
    var layout: LibraryLayout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "likes.layout") }
    }
    var sort: LikesSort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "likes.sort") }
    }
    var query = ""

    init() {
        let defaults = UserDefaults.standard
        layout = defaults.string(forKey: "likes.layout").flatMap(LibraryLayout.init) ?? .list
        sort = defaults.string(forKey: "likes.sort").flatMap(LikesSort.init) ?? .recent
    }
}

/// Likes the way SoundCloud presents them: a list or a grid of the same collection, with a filter
/// and a sort over what's loaded.
struct LikesView: View {
    let model: AppModel
    /// Lets a #Preview show the other layout without writing to the stored preference.
    var previewLayout: LibraryLayout? = nil

    @State private var isStarting = false

    @Environment(\.metrics) private var metrics

    private var feed: TrackFeed { model.library.likes }
    private var controls: LikesControls { model.likesControls }
    private var query: String { controls.query }
    private var sort: LikesSort { controls.sort }

    /// Filter and sort together decide which rows are on screen, so either change means the reader
    /// is looking at a different list and the old scroll offset is meaningless.
    private var listToken: String { query + "|" + sort.rawValue }
    private var activeLayout: LibraryLayout { previewLayout ?? controls.layout }

    /// api-v2 neither sorts nor searches likes, so a sort or a filter walks the whole collection in;
    /// meanwhile it runs over what has come and settles as the rest lands.
    private var needsWholeCollection: Bool {
        sort != .recent || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tracks: [SCTrack] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = needle.isEmpty ? feed.tracks : feed.tracks.filter {
            $0.title.lowercased().contains(needle) || $0.artistLine.lowercased().contains(needle)
        }
        switch sort {
        case .recent: return matched
        case .title: return matched.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: return matched.sorted { $0.artistLine.localizedStandardCompare($1.artistLine) == .orderedAscending }
        case .longest: return matched.sorted { $0.duration > $1.duration }
        case .plays: return matched.sorted { ($0.playbackCount ?? 0) > ($1.playbackCount ?? 0) }
        }
    }

    var body: some View {
        // Filtered and sorted once per pass: read as a property, it ran again for every row.
        let rows = tracks
        content(rows)
            .task { feed.loadIfNeeded() }
            .onChange(of: needsWholeCollection, initial: true) { _, needed in
                if needed { feed.loadAll() }
            }
    }

    // Scrolls away with the list: what it holds acts on the collection, the toolbar holds the view of it.
    private func header(_ rows: [SCTrack]) -> some View {
        HStack(spacing: 10) {
            Button { play() } label: {
                Label("Play", systemImage: "play.fill").frame(minWidth: 62)
            }
            .glassButton(.prominent)
            .disabled(rows.isEmpty || isStarting)

            Button { play(shuffled: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .glassButton()
            .disabled(rows.isEmpty || isStarting)

            if isStarting || feed.isLoadingAll { FaderLoader(size: 20) }

            Text(countLabel(rows))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, gutter)
        .padding(.top, 16)
    }

    /// The total comes from the profile, not from the feed: the feed only ever knows the pages it
    /// has fetched, and a filter searches those pages alone, so it gets no denominator at all.
    private func countLabel(_ rows: [SCTrack]) -> String {
        let shown = rows.count
        if feed.isLoadingAll {
            let total = model.library.meUser?.likesCount.map { " of \($0.formatted())" } ?? ""
            return "Loading all likes · \(feed.tracks.count.formatted())\(total)"
        }
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(shown.formatted()) matching"
        }
        guard let total = model.library.meUser?.likesCount else {
            return "\(shown.formatted()) track\(shown == 1 ? "" : "s")"
        }
        return "\(total.formatted()) track\(total == 1 ? "" : "s")"
    }

    private func content(_ rows: [SCTrack]) -> some View {
        // Fills the column whatever branch wins. Without this the empty state is shorter than the
        // page, the outer VStack centres itself, and the header slides into the middle of the
        // window as you type a filter that matches nothing.
        contentBody(rows)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func contentBody(_ rows: [SCTrack]) -> some View {
        // Of the whole feed, not the filtered rows: a filter matching nothing is no first load.
        switch ListPhase(feed, isEmpty: feed.tracks.isEmpty) {
        case .loading:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(rows)
                    Group {
                        if activeLayout == .list {
                            LikeCardsSkeleton()
                        } else {
                            CardGridSkeleton()
                        }
                    }
                    .padding(.horizontal, gutter)
                }
                .padding(.bottom, 16)
            }
        case .failed(let error):
            LoadFailure(title: "Couldn't load your likes", message: error) {
                Task { await feed.loadMore() }
            }
        case .empty, .rows:
            if rows.isEmpty {
                emptyState
            } else if activeLayout == .list {
                feedList(rows)
            } else {
                grid(rows)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                query.isEmpty ? "No likes yet" : "Nothing matches",
                systemImage: "heart",
                description: Text(query.isEmpty
                                  ? "Tracks you like on SoundCloud show up here."
                                  : feed.isComplete
                                    ? "No match in your \(feed.tracks.count) likes."
                                    : "No match in the \(feed.tracks.count) tracks loaded so far."))
            FeedFooter(isLoading: feed.isLoading, error: feed.nextPageError,
                       retry: feed.loadMore)
        }
        .frame(maxHeight: .infinity)
    }

    private func feedList(_ rows: [SCTrack]) -> some View {
        let queue = feed.playQueue(rows, scoped: !playsWholeCollection)
        return CardCollection(items: rows,
                              rows: .measured(by: LikeCard.heightVariant(of:), token: metrics.listArtwork),
                              insets: NSEdgeInsets(top: 16, left: gutter, bottom: 16, right: gutter),
                              spacing: 20,
                              bottomReserve: PlayerPill.reservedHeight,
                              topToken: listToken,
                              paging: ListPaging(feed),
                              chrome: CardCollectionChrome(header: AnyView(header(rows))),
                              onClick: ShellSearchField.endEditing,
                              onPrefetch: LikeCard.warm) { track in
            LikeCard(track: track, player: model.player, queue: queue)
        }
        // The list runs under the toolbar and over the player's reserve, which come back as its own insets.
        .ignoresSafeArea()
    }

    /// The same AppKit list as the rows, in columns: a SwiftUI grid of these cards was the one list
    /// left that stuttered, and it had only the system's blur under the pinned bar, not the fade.
    private func grid(_ rows: [SCTrack]) -> some View {
        let queue = feed.playQueue(rows, scoped: !playsWholeCollection)
        return CardCollection(items: rows,
                              // Every card the same height — the title is cut to one line — so one is measured.
                              rows: .grid(CardGrid(minimum: metrics.card, spacing: 18), token: metrics.card),
                              insets: NSEdgeInsets(top: 16, left: gutter, bottom: 16, right: gutter),
                              spacing: 22,
                              bottomReserve: PlayerPill.reservedHeight,
                              topToken: listToken,
                              paging: ListPaging(feed),
                              chrome: CardCollectionChrome(header: AnyView(header(rows))),
                              onClick: ShellSearchField.endEditing,
                              onPrefetch: { ArtworkPrefetcher.warm($0.map(\.coverURL), size: .hero) }) { track in
            TrackCard(track: track, player: model.player, queue: queue)
        }
        .ignoresSafeArea()
    }

    /// A filter or a custom sort makes the visible list the intent; otherwise every entry point
    /// here plays the whole likes collection, not the pages the feed happens to have fetched.
    private var queue: PlayQueue {
        feed.playQueue(tracks, scoped: !playsWholeCollection)
    }

    private var playsWholeCollection: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sort == .recent
    }

    private func play(shuffled: Bool? = nil) {
        guard !tracks.isEmpty else { return }
        run { await queue.start(shuffled: shuffled, on: model.player) }
    }

    /// Walking the id list is a round trip, so the buttons say they are working.
    private func run(_ work: @escaping () async -> Void) {
        isStarting = true
        Task {
            defer { isStarting = false }
            await work()
        }
    }
}
