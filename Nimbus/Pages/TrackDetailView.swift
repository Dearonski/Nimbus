import SwiftUI

struct TrackDetailView: View {
    let track: SCTrack
    let model: AppModel

    @Environment(\.metrics) private var metrics

    @State private var page: TrackPageModel?

    /// Shared with the hero, whose artwork lines up with this column exactly, the way it does on
    /// the site — both are 336 there, sitting on the same right edge.
    static let railMinimum: CGFloat = 1000
    static let railWidth: CGFloat = 336

    private var showsRail: Bool { metrics.usable >= Self.railMinimum }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let page {
                    TrackHero(track: track, model: model, page: page)
                        .padding(.horizontal, gutter)
                        .padding(.top, 10)

                    if showsRail {
                        HStack(alignment: .top, spacing: 28) {
                            main(page)
                            // Scrolls with the page, unlike the artist rail: here the column is
                            // long and the comments are what you came to read.
                            TrackRail(page: page, model: model)
                                .frame(width: Self.railWidth, alignment: .leading)
                        }
                        .padding(.horizontal, gutter + TrackHero.contentInset)
                        .padding(.top, 22)
                        .padding(.bottom, 8)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            main(page)
                            TrackRail(page: page, model: model)
                        }
                        .padding(.horizontal, gutter + TrackHero.contentInset)
                        .padding(.top, 22)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .navigationTitle(track.title)
        .task(id: track.id) {
            let pageModel = TrackPageModel(track: track, api: model.api)
            page = pageModel
            await pageModel.load()
        }
    }

    private func main(_ page: TrackPageModel) -> some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            details
            TrackComments(page: page, model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var details: some View {
        let text = track.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty || !track.tags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !text.isEmpty {
                    ArtistBio(text: text)
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
