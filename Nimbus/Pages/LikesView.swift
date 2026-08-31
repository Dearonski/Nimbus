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

    private var countLabel: String {
        let loaded = feed.tracks.count
        let shown = tracks.count
        if shown != loaded { return "\(shown) of \(loaded)" }
        return "\(loaded) track\(loaded == 1 ? "" : "s")"
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
            ContentUnavailableView(
                query.isEmpty ? "No likes yet" : "Nothing matches",
                systemImage: "heart",
                description: Text(query.isEmpty
                                  ? "Tracks you like on SoundCloud show up here."
                                  : "No loaded track matches \"\(query)\"."))
        } else if activeLayout == .list {
            feedList
        } else {
            grid
        }
    }

    private var feedList: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(tracks) { track in
                    LikeCard(track: track, player: model.player, context: tracks,
                             onPlay: { start($0) })
                        .onAppear {
                            if track.id == tracks.last?.id { Task { await feed.loadMore() } }
                        }
                }
                if feed.isLoading {
                    ProgressView().controlSize(.small).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 16)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.card), spacing: 18)], spacing: 22) {
                ForEach(tracks) { track in
                    TrackCard(track: track, player: model.player, context: tracks)
                        .onAppear {
                            if track.id == tracks.last?.id { Task { await feed.loadMore() } }
                        }
                }
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 16)

            if feed.isLoading {
                ProgressView().controlSize(.small).padding(.bottom, 16)
            }
        }
    }

    /// A filter or a custom sort makes the visible list the intent; otherwise both buttons play the
    /// whole likes collection, not just the pages the feed happens to have fetched.
    private var playsWholeCollection: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sort == .recent
    }

    /// Starts a single track inside the whole collection rather than inside the loaded page.
    private func start(_ track: SCTrack) {
        let visible = tracks
        isStarting = true
        Task {
            defer { isStarting = false }
            guard playsWholeCollection else {
                await model.player.play(track, in: visible)
                return
            }
            let ids = await model.library.likedIDs()
            guard !ids.isEmpty else {
                await model.player.play(track, in: visible)
                return
            }
            await model.player.play(ids: ids, startingAt: track.id, shuffled: false) { chunk in
                await model.library.tracks(ids: chunk)
            }
        }
    }

    private func play(shuffled: Bool) {
        let visible = tracks
        guard let first = visible.first else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            guard playsWholeCollection else {
                if shuffled {
                    await model.player.playShuffled(visible)
                } else {
                    await model.player.play(first, in: visible)
                }
                return
            }
            let ids = await model.library.likedIDs()
            guard !ids.isEmpty else {
                await model.player.play(first, in: visible)
                return
            }
            await model.player.play(ids: ids, shuffled: shuffled) { chunk in
                await model.library.tracks(ids: chunk)
            }
        }
    }
}
