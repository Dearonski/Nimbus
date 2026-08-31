import SwiftUI

/// Shown while the search field is focused but empty: browse the top chart per genre.
struct GenreGridView: View {
    @Environment(\.metrics) private var metrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Browse").font(.title2).bold()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.tile), spacing: 12)], spacing: 12) {
                    ForEach(Array(SCGenre.browse.enumerated()), id: \.element) { index, genre in
                        NavigationLink(value: genre) {
                            GenreTile(genre: genre, index: index)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
    }
}

struct GenreTile: View {
    let genre: SCGenre
    let index: Int

    @Environment(\.metrics) private var metrics

    var body: some View {
        let hue = Double(index) / Double(max(SCGenre.browse.count, 1))
        RoundedRectangle(cornerRadius: 10)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.85),
                        Color(hue: hue, saturation: 0.75, brightness: 0.5),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(height: metrics.tile * 0.48)
            .overlay(alignment: .bottomLeading) {
                Text(genre.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
            }
    }
}

struct GenreChartView: View {
    let genre: SCGenre
    let model: AppModel

    @State private var tracks: [SCTrack] = []
    @State private var nextHref: String?
    @State private var isLoading = true

    var body: some View {
        TrackTable(tracks: tracks, player: model.player, isLoading: isLoading, onReachEnd: loadMore)
            .navigationTitle(genre.name)
            .task {
                guard tracks.isEmpty else { return }
                let page = try? await model.api.genrePopular(slug: genre.slug)
                tracks = page?.collection ?? []
                nextHref = page?.nextHref
                isLoading = false
            }
    }

    private func loadMore() async {
        guard let href = nextHref else { return }
        nextHref = nil
        let page = try? await model.api.nextGenrePopularPage(href)
        tracks.append(contentsOf: page?.collection ?? [])
        nextHref = page?.nextHref
    }
}
