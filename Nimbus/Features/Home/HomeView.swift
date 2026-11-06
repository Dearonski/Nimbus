import SwiftUI

/// Home answers "what should I play?", not "what is popular". Its spine is SoundCloud's own
/// discover feed (`/mixed-selections`): a featured mix, your re-entry points, then the curated
/// shelves. The chart is one section among many, not the page.
///
/// Shelves rotate archetype (square sets → people circles → wide mixes) so the page never reads
/// as the same card repeated, which is the failure mode of both our old Home and nuage's.
struct HomeView: View {
    let model: AppModel
    @State private var genre = SCGenre.charts[0]
    @State private var position = ScrollPosition()
    // Read only when the chart folds; as state, every scrolled frame would rebuild the page.
    @State private var geometry = ScrollMarks()

    private var selections: [SCMixedSelection] { model.library.selections }
    private var featured: SCPlaylist? { selections.first?.playlists.first }
    private var recentTracks: [SCTrack] { model.library.history.tracks }

    /// The people shelf SoundCloud sends ("Artists to watch out for"); when the feed has none,
    /// fall back to the artists behind the chart — free, no extra request.
    private var artists: [SCUser] {
        // The people shelf can repeat a user; a duplicate id makes ForEach render undefined rows.
        let shelf = selections.first(where: \.isPeopleShelf)?.users ?? model.library.chartArtists
        var seen = Set<Int>()
        return shelf.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                FeaturedMix(playlist: featured, eyebrow: selections.first?.title, model: model)

                if !recentTracks.isEmpty {
                    RecentGrid(tracks: Array(recentTracks.prefix(6)), player: model.player)
                }

                ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
                    SelectionShelf(shelf: shelf, style: index.isMultiple(of: 2) ? .square : .wide,
                                   model: model)

                    if index == 0, !artists.isEmpty {
                        ArtistShelf(artists: Array(artists.prefix(12)))
                    }
                    if index == 1 { chart }
                }

                if shelves.count < 2 { chart }
            }
            .padding(.vertical, 20)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { [geometry] _, new in geometry.scroll = new }
        .task {
            model.library.loadSelectionsIfNeeded()
            model.library.history.loadIfNeeded()
            model.library.loadTrendingIfNeeded()
        }
        .onChange(of: genre) { _, newGenre in
            model.library.reloadTrending(genre: newGenre)
        }
    }

    private var chart: some View {
        ChartSection(tracks: model.library.trending, player: model.player,
                     genre: $genre, isLoading: model.library.isLoadingTrending) {
            // By offset, not by id: `scrollTo(id:anchor:)` landed the header flush under the toolbar, and a
            // marker placed above it was ignored. This puts it a section gap below the toolbar's inset.
            guard let scroll = geometry.scroll else { return }
            let delta = geometry.chartTop - scroll.contentInsets.top - ChartSection.landingRoom
            position.scrollTo(y: scroll.contentOffset.y + delta)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { [geometry] in
            geometry.chartTop = $0
        }
    }

    /// Sections we render ourselves, in richer form, than the shelf the feed would give us.
    private static let ownedShelves: Set<String> = ["recently played", "charts", "history"]

    /// The featured mix is lifted out of the first shelf so it isn't shown twice.
    private var shelves: [ShelfData] {
        var isFirst = true
        return selections.compactMap { selection in
            guard !selection.isPeopleShelf,
                  !Self.ownedShelves.contains(selection.title.lowercased())
            else { return nil }
            var playlists = selection.playlists
            if isFirst {
                isFirst = false
                playlists = Array(playlists.dropFirst())
            }
            guard !playlists.isEmpty else { return nil }
            return ShelfData(id: selection.id, title: selection.title,
                             subtitle: selection.description, playlists: playlists)
        }
    }
}

struct ShelfData: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let playlists: [SCPlaylist]
}

// MARK: - Recently played — the only 2-D grid, the density hit

/// Deliberately not "pick up where you left off": no per-track playback offset is stored
/// anywhere, so a tap restarts the track. The label names what actually happens.
struct RecentGrid: View {
    let tracks: [SCTrack]
    let player: PlayerEngine

    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recently played", size: 18)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.rowGrid), spacing: 12)], spacing: 12) {
                ForEach(tracks) { track in
                    RecentPill(track: track, player: player, queue: .exactly(tracks, context: .history))
                }
            }
            .padding(.horizontal, gutter)
        }
    }
}

// MARK: - Selection shelves — SoundCloud's own discover feed

enum ShelfStyle {
    case square, wide
}

struct SelectionShelf: View {
    let shelf: ShelfData
    let style: ShelfStyle
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: shelf.title, subtitle: shelf.subtitle, size: 20)

            Shelf {
                ForEach(shelf.playlists) { playlist in
                    switch style {
                    case .square: PlaylistCard(playlist: playlist, model: model)
                    case .wide: WideSetCard(playlist: playlist, model: model)
                    }
                }
            }
        }
    }
}

// MARK: - Artists — the only round shape on the page

struct ArtistShelf: View {
    let artists: [SCUser]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Artists on the rise", size: 20)
            Shelf(spacing: 20) {
                ForEach(artists) { ArtistCircle(artist: $0) }
            }
        }
    }
}

// MARK: - The chart — one section among many, not the page

private final class ScrollMarks {
    var scroll: ScrollGeometry?
    var chartTop: CGFloat = 0
}

struct ChartSection: View {
    let tracks: [SCTrack]
    let player: PlayerEngine
    @Binding var genre: SCGenre
    var isLoading = false
    // Folding the long list up leaves the reader below the chart, among the shelves that followed it.
    var onCollapse: () -> Void = {}

    // The page's own gap between sections.
    static let landingRoom: CGFloat = 34

    @State private var showAll = false

    private var visible: [SCTrack] { showAll ? tracks : Array(tracks.prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Charts", subtitle: "What's trending right now", size: 20)

            GenreChipsRow(selection: $genre)

            if tracks.isEmpty && isLoading {
                ChartRowsSkeleton(count: 5)
                    .padding(.horizontal, gutter - ChartRow.inset)
            } else {
                let rankWidth = ChartRow.rankWidth(for: visible.count)
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, track in
                        ChartRow(rank: index + 1, track: track, player: player, queue: .exactly(tracks),
                                 rankWidth: rankWidth)
                    }
                }
                .padding(.horizontal, gutter - ChartRow.inset)

                if tracks.count > 5 {
                    Button(showAll ? "Show less" : "Show all \(tracks.count)") {
                        if showAll {
                            // Up to the chart first, then fold: folding under a reader at the page's end
                            // dragged the scroll offset along every frame, and that is what stuttered.
                            withAnimation(.smooth(duration: 0.3)) { onCollapse() }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(280))
                                withAnimation(.snappy) { showAll = false }
                            }
                        } else {
                            withAnimation(.snappy) { showAll = true }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, gutter)
                }
            }
        }
    }
}
