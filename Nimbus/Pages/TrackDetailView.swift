import NukeUI
import SwiftUI

struct TrackDetailView: View {
    let track: SCTrack
    let model: AppModel

    @State private var waveform = WaveformLoader()

    private var isCurrent: Bool { track.id == model.player.currentTrack?.id }
    private var isLiked: Bool { model.library.isLiked(track) }
    private var progress: Double {
        guard isCurrent, model.player.duration > 0 else { return 0 }
        return model.player.currentTime / model.player.duration
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 20) {
                    LazyImage(url: track.artworkURL.scArtwork()) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 8, y: 4)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(track.title).font(.largeTitle).bold().lineLimit(3)
                        NavigationLink(value: track.user) {
                            HStack(spacing: 6) {
                                Text(track.artistLine).font(.title3)
                                if track.user.verified == true {
                                    Image(systemName: "checkmark.seal.fill").imageScale(.small)
                                }
                            }
                            .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 10) {
                            if let genre = track.genre, !genre.isEmpty { GenreBadge(text: genre) }
                            if let album = track.album, !album.isEmpty {
                                Label(album, systemImage: "square.stack").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(timeString(Double(track.duration) / 1000))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 12) {
                            Button(action: play) {
                                Label(isCurrent && model.player.isPlaying ? "Pause" : "Play",
                                      systemImage: isCurrent && model.player.isPlaying ? "pause.fill" : "play.fill")
                                    .frame(minWidth: 100)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button { model.library.toggleLike(track) } label: {
                                Label(isLiked ? "Liked" : "Like",
                                      systemImage: isLiked ? "heart.fill" : "heart")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(isLiked ? .scOrange : .secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                WaveformView(waveform: waveform.waveform, progress: progress)
                    .frame(height: 64)

                detailStats
            }
            .padding(24)
        }
        .navigationTitle(track.title)
        .task(id: track.id) { waveform.load(track.waveformURL) }
    }

    private var detailStats: some View {
        HStack(spacing: 28) {
            statColumn("Plays", "play.fill", track.playbackCount)
            statColumn("Likes", "heart.fill", track.likesCount)
            statColumn("Comments", "text.bubble.fill", track.commentCount)
            statColumn("Reposts", "arrow.2.squarepath", track.repostsCount)
            Spacer()
        }
    }

    @ViewBuilder
    private func statColumn(_ label: String, _ symbol: String, _ count: Int?) -> some View {
        if let count, count > 0 {
            VStack(spacing: 4) {
                Label(countString(count), systemImage: symbol).font(.headline).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func play() {
        if isCurrent {
            model.player.togglePlayPause()
        } else {
            Task { await model.player.play(track) }
        }
    }
}

struct GenreBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
