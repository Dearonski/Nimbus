import SwiftUI

// Shown while the search field is empty: each genre's trending playlist, as soundcloud.com's own shelf shows it.
struct GenreGridView<Header: View>: View {
    let model: AppModel
    @ViewBuilder var header: Header

    @Environment(\.metrics) private var metrics

    private var charts: GenreCharts { model.library.genreCharts }

    private static var spacing: CGFloat { 18 }

    // As many columns as fit a shelf-sized card, then flexible: fixed ones held the page at its old width.
    private var columns: [GridItem] {
        let count = max(Int((metrics.usable + Self.spacing) / (metrics.card + Self.spacing)), 1)
        return Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Text("Browse").font(.title2).bold()
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(Array(SCGenre.charts.enumerated()), id: \.element) { index, genre in
                        GenreCard(genre: genre, index: index, cover: charts.cover(for: genre, in: SCGenre.charts),
                                  model: model)
                            .task { await charts.loadCover(for: genre) }
                    }
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, gutter)
        }
    }
}

struct GenreCard: View {
    let genre: SCGenre
    let index: Int
    let cover: String?
    let model: AppModel

    @State private var isStarting = false

    var body: some View {
        MediaCard(isBusy: isStarting, fillsColumn: true, play: play) {
            ZStack {
                // Until the cover comes, and for a chart that has none.
                SCGradient(index: SCGradient.index(for: index))
                if let url = cover.scArtwork(.hero) {
                    Artwork(url: url, placeholderOpacity: 0).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: cover)
        } caption: {
            NavButton(value: genre) {
                CardCaption(title: genre.name, subtitle: "Trending", fillsColumn: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func play() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            if let playlist = await model.library.genreCharts.playlist(for: genre) { await model.play(playlist) }
        }
    }
}

// A genre is its trending playlist, opened on the same page as any other set.
struct GenreChartView: View {
    let genre: SCGenre
    let model: AppModel

    @State private var playlist: SCPlaylist?
    @State private var failed = false

    var body: some View {
        Group {
            if let playlist {
                PlaylistPage(playlist: playlist, model: model)
            } else if failed {
                LoadFailure(message: "Couldn't load the chart") { Task { await load() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if playlist == nil { await load() } }
    }

    private func load() async {
        failed = false
        playlist = await model.library.genreCharts.playlist(for: genre)
        failed = playlist == nil
    }
}
