import SwiftUI

enum LibraryLayout: String, CaseIterable {
    case list, grid

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

    @Environment(\.metrics) private var metrics

    private var feed: TrackFeed { model.library.likes }
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
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { feed.loadInitialIfNeeded() }
        .paginatesWhileShort(!query.isEmpty && tracks.count < 30,
                             pagesLoaded: feed.pagesLoaded, resetOn: query) {
            await feed.loadMore()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Likes").font(.system(size: 26, weight: .bold))
                Text(countLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                Button { play(shuffled: false) } label: {
                    Label("Play", systemImage: "play.fill").frame(minWidth: 62)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty || isStarting)

                Button { play(shuffled: true) } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .disabled(tracks.isEmpty || isStarting)

                if isStarting { ProgressView().controlSize(.small) }

                Spacer(minLength: 12)

                filterField

                Picker("", selection: $sort) {
                    ForEach(LikesSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)

                layoutPicker
            }
        }
        .padding(.horizontal, gutter)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// The total comes from the profile, not from the feed: the feed only ever knows the pages it
    /// has fetched, and a filter searches those pages alone, so it gets no denominator at all.
    private var countLabel: String {
        let shown = tracks.count
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
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 190)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    private var layoutPicker: some View {
        Picker("", selection: $layout) {
            ForEach(LibraryLayout.allCases, id: \.self) { option in
                Image(systemName: option.systemImage).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 84)
    }

    @ViewBuilder
    private var content: some View {
        if feed.tracks.isEmpty && feed.isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tracks.isEmpty {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    query.isEmpty ? "No likes yet" : "Nothing matches",
                    systemImage: "heart",
                    description: Text(query.isEmpty
                                      ? "Tracks you like on SoundCloud show up here."
                                      : "No match in the \(feed.tracks.count) tracks loaded so far."))
                FeedFooter(isLoading: feed.isLoading)
            }
        } else if activeLayout == .list {
            feedList
        } else {
            grid
        }
    }

    private var feedList: some View {
        let rows = tracks
        let triggers = rows.pagingTriggerIDs
        return ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(rows) { track in
                    LikeCard(track: track, player: model.player, queue: queue)
                        .paginates(triggers.contains(track.id)) { await feed.loadMore() }
                }
                FeedFooter(isLoading: feed.isLoading)
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 16)
        }
    }

    private var grid: some View {
        let rows = tracks
        let triggers = rows.pagingTriggerIDs
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.card), spacing: 18)], spacing: 22) {
                ForEach(rows) { track in
                    TrackCard(track: track, player: model.player, queue: queue)
                        .paginates(triggers.contains(track.id)) { await feed.loadMore() }
                }
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 16)

            FeedFooter(isLoading: feed.isLoading, padding: 0).padding(.bottom, 16)
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

    private func start(_ track: SCTrack) {
        run { await queue.start(track, on: model.player) }
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
