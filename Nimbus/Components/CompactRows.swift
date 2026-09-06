import SwiftUI

struct RecentPill: View {
    let track: SCTrack
    let player: PlayerEngine
    let context: [SCTrack]

    @State private var hovering = false
    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    @Environment(\.metrics) private var metrics

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                Artwork(track, size: .mid)
                    .frame(width: metrics.rowArtwork, height: metrics.rowArtwork)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    Text(track.artistLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                    .opacity(hovering ? 1 : 0)
                    .padding(.trailing, 12)
            }
            .padding(6)
            .frame(height: 60)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.04))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .trackContextMenu(track, player: player)
    }

    private func play() {
        if isCurrent {
            player.togglePlayPause()
        } else {
            Task { await player.play(track, in: context) }
        }
    }
}

struct ChartRow: View {
    let rank: Int
    let track: SCTrack
    let player: PlayerEngine
    let context: [SCTrack]

    @State private var hovering = false
    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 30, weight: .black))
                .fontWidth(.compressed)
                .monospacedDigit()
                .foregroundStyle(rank <= 3 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.35)))
                .frame(width: 42, alignment: .trailing)

            Artwork(track, size: .mid)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                NavButton(value: track.user) {
                    Text(track.artistLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            if isCurrent && player.isPlaying {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.tint)
            }
            if let plays = track.playbackCount {
                Text(countString(plays))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 52, alignment: .trailing)
            }
            Text(timeString(Double(track.duration) / 1000))
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { Task { await player.play(track, in: context) } }
        .trackContextMenu(track, player: player)
    }
}
