import NukeUI
import SwiftUI

struct QueueButton: View {
    @Binding var isVisible: Bool

    var body: some View {
        Button { isVisible.toggle() } label: { Image(systemName: "list.bullet") }
            .foregroundStyle(isVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
}

/// Trailing queue panel that overlaps the detail column instead of splitting it — the way Music's
/// Playing Next slides in over the content.
struct QueueSidebar: View {
    static let width: CGFloat = 320

    let player: PlayerEngine
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Playing Next").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if player.queue.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("Queue is empty").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(player.queue) { track in
                        QueueItemView(track: track, isCurrent: track.id == player.currentTrack?.id) {
                            if let index = player.queue.firstIndex(where: { $0.id == track.id }) {
                                Task { await player.jump(to: index) }
                            }
                        }
                    }
                    .onMove { player.moveInQueue(from: $0, to: $1) }
                    .onDelete { player.removeFromQueue(atOffsets: $0) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, x: -4)
    }
}

struct QueueItemView: View {
    let track: SCTrack
    let isCurrent: Bool
    let onJump: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Click the artwork to jump; the rest of the row stays free for drag-to-reorder.
            Button(action: onJump) {
                ZStack {
                    LazyImage(url: track.artworkURL.flatMap(URL.init)) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    if hovering {
                        Color.black.opacity(0.4)
                        Image(systemName: "play.fill").foregroundStyle(.white).font(.system(size: 14))
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text(track.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.tint)
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }
}
