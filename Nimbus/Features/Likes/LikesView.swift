import SwiftUI

enum LibraryLayout: String, CaseIterable, Identifiable {
    case list, grid

    var id: Self { self }

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

/// Likes the way SoundCloud presents them: a list or a grid of the same collection, with a filter
/// and a sort over what's loaded.
struct LikesView: View {
    let model: AppModel
    /// Lets a #Preview show the other layout without writing to the stored preference.
    var previewLayout: LibraryLayout? = nil

    @AppStorage("likes.layout") private var layout: LibraryLayout = .list
    @AppStorage("likes.sort") private var sort: LikesSort = .recent
    @State private var query = ""
    @State private var isStarting = false
    @FocusState private var filterFocused: Bool

    @Environment(\.metrics) private var metrics

    private var feed: TrackFeed { model.library.likes }

    private static let topAnchor = "likes.top"
    /// Filter and sort together decide which rows are on screen, so either change means the reader
    /// is looking at a different list and the old scroll offset is meaningless.
    private var listToken: String { query + "|" + sort.rawValue }
    private var activeLayout: LibraryLayout { previewLayout ?? layout }

    /// Filtering and sorting run over the pages fetched so far — the api-v2 likes collection has no
    /// server-side search, and asking for every page up front would be thousands of tracks.
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
        VStack(spacing: 0) {
            header(rows)
            Divider()
            content(rows)
        }
        .task { feed.loadInitialIfNeeded() }
        .paginatesWhileShort(!query.isEmpty && rows.count < 30,
                             pagesLoaded: feed.pagesLoaded, resetOn: query) {
            await feed.loadMore()
        }
    }

    private func header(_ rows: [SCTrack]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // No heading of its own: the titlebar names the section, the way it does on every
            // other one. The count keeps its place beside the buttons.
            HStack(spacing: 10) {
                Button { play(shuffled: false) } label: {
                    Label("Play", systemImage: "play.fill").frame(minWidth: 62)
                }
                .glassButton(.prominent)
                .disabled(rows.isEmpty || isStarting)

                Button { play(shuffled: true) } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .glassButton()
                .disabled(rows.isEmpty || isStarting)

                if isStarting { FaderLoader(size: 20) }

                Text(countLabel(rows))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                filterField

                sortMenu

                layoutPicker
            }
        }
        .padding(.horizontal, gutter)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// The total comes from the profile, not from the feed: the feed only ever knows the pages it
    /// has fetched, and a filter searches those pages alone, so it gets no denominator at all.
    private func countLabel(_ rows: [SCTrack]) -> String {
        let shown = rows.count
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(shown.formatted()) matching"
        }
        guard let total = model.library.meUser?.likesCount else {
            return "\(shown.formatted()) track\(shown == 1 ? "" : "s")"
        }
        return "\(total.formatted()) track\(total == 1 ? "" : "s")"
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($filterFocused)
                // Esc and Return both leave the field with the filter intact: while it has focus
                // the space bar types instead of playing, so leaving must not need the mouse.
                .onSubmit { filterFocused = false }
                .onKeyPress(.escape) {
                    filterFocused = false
                    return .handled
                }
                .onChange(of: filterFocused) { _, focused in model.isTypingInField = focused }
                .onChange(of: model.focusFieldRequest) { _, _ in filterFocused = true }
                .onDisappear { model.isTypingInField = false }
            if !query.isEmpty {
                Button { query = ""; filterFocused = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 190, height: GlassMetrics.height(.regular))
        .glassCapsule()
    }

    private var sortMenu: some View {
        Menu {
            // Inline, or the picker's own label becomes a "Sort ▸" submenu you have to open
            // before the options appear.
            Picker("", selection: $sort) {
                ForEach(LikesSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(sort.rawValue)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .glassButton()
        .fixedSize()
    }

    private var layoutPicker: some View {
        GlassTabBar(tabs: LibraryLayout.allCases, title: \.rawValue,
                    icon: \.systemImage, selection: $layout)
    }

    private func content(_ rows: [SCTrack]) -> some View {
        // Fills the column whatever branch wins. Without this the empty state is shorter than the
        // page, the outer VStack centres itself, and the header slides into the middle of the
        // window as you type a filter that matches nothing.
        contentBody(rows)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A ScrollView of custom cards is not focusable, so unlike a List it never takes focus
            // off the filter when clicked. Simultaneous, so the card underneath still gets the tap.
            .simultaneousGesture(TapGesture().onEnded { filterFocused = false })
    }

    @ViewBuilder
    private func contentBody(_ rows: [SCTrack]) -> some View {
        if feed.tracks.isEmpty && feed.isLoading {
            ScrollView {
                Group {
                    if activeLayout == .list {
                        LikeCardsSkeleton()
                    } else {
                        CardGridSkeleton()
                    }
                }
                .padding(.horizontal, gutter)
                .padding(.vertical, 16)
            }
        } else if feed.tracks.isEmpty, let error = feed.error {
            LoadFailure(title: "Couldn't load your likes", message: error) {
                Task { await feed.loadMore() }
            }
        } else if rows.isEmpty {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    query.isEmpty ? "No likes yet" : "Nothing matches",
                    systemImage: "heart",
                    description: Text(query.isEmpty
                                      ? "Tracks you like on SoundCloud show up here."
                                      : "No match in the \(feed.tracks.count) tracks loaded so far."))
                FeedFooter(isLoading: feed.isLoading, error: feed.nextPageError,
                           retry: feed.loadMore)
            }
        } else if activeLayout == .list {
            feedList(rows)
        } else {
            grid(rows)
        }
    }

    private func feedList(_ rows: [SCTrack]) -> some View {
        let triggers = rows.pagingTriggerIDs
        let queue = feed.playQueue(rows, scoped: !playsWholeCollection)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    scrollAnchor
                    LazyVStack(spacing: 20) {
                        ForEach(rows) { track in
                            LikeCard(track: track, player: model.player, queue: queue)
                                .paginates(triggers.contains(track.id)) { await feed.loadMore() }
                        }
                        FeedFooter(isLoading: feed.isLoading, error: feed.nextPageError,
                                   retry: feed.loadMore)
                    }
                    .padding(.horizontal, gutter)
                    .padding(.vertical, 16)
                }
            }
            .onChange(of: listToken) { _, _ in proxy.scrollTo(Self.topAnchor, anchor: .top) }
        }
    }

    /// Zero-height and outside the stack's spacing, so it never opens a gap above the first row.
    private var scrollAnchor: some View {
        Color.clear.frame(height: 0).id(Self.topAnchor)
    }

    private func grid(_ rows: [SCTrack]) -> some View {
        let triggers = rows.pagingTriggerIDs
        let queue = feed.playQueue(rows, scoped: !playsWholeCollection)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    scrollAnchor
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.card), spacing: 18)],
                              spacing: 22) {
                        ForEach(rows) { track in
                            TrackCard(track: track, player: model.player, queue: queue)
                                .paginates(triggers.contains(track.id)) { await feed.loadMore() }
                        }
                    }
                    .padding(.horizontal, gutter)
                    .padding(.vertical, 16)

                    FeedFooter(isLoading: feed.isLoading, padding: 0, error: feed.nextPageError,
                               retry: feed.loadMore)
                        .padding(.bottom, 16)
                }
            }
            .onChange(of: listToken) { _, _ in proxy.scrollTo(Self.topAnchor, anchor: .top) }
        }
    }

    /// A filter or a custom sort makes the visible list the intent; otherwise every entry point
    /// here plays the whole likes collection, not the pages the feed happens to have fetched.
    private var queue: PlayQueue {
        feed.playQueue(tracks, scoped: !playsWholeCollection)
    }

    private var playsWholeCollection: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sort == .recent
    }

    private func play(shuffled: Bool) {
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
