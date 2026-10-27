import SwiftUI

/// Shown while the search field is empty: browse the top chart per genre.
struct GenreGridView: View {
    @Environment(\.metrics) private var metrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Browse").font(.title2).bold()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.tile), spacing: 12)], spacing: 12) {
                    ForEach(Array(SCGenre.browse.enumerated()), id: \.element) { index, genre in
                        NavButton(value: genre) {
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

    @State private var chart: Pager<SCTrack>?

    var body: some View {
        let tracks = chart?.items ?? []
        TrackTable(tracks: tracks, player: model.player, queue: .exactly(tracks),
                   paging: chart.map { ListPaging($0) } ?? ListPaging(isLoading: true))
            .overlay {
                if let chart, let error = chart.firstPageError, !chart.isLoading {
                    LoadFailure(title: "Couldn't load the chart", message: error) {
                        Task { await chart.loadMore() }
                    }
                }
            }
            .task {
                if chart == nil {
                    let api = model.api, slug = genre.slug
                    chart = model.pages.model(for: .genre(slug)) {
                        Pager(first: { try await api.genrePopular(slug: slug).page },
                              next: { try await api.page(after: $0, as: SCTrackSearchPage.self).page })
                    }
                }
                guard let chart, !chart.hasLoaded else { return }
                await chart.loadMore()
            }
    }
}
