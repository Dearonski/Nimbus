import NukeUI
import SwiftUI

struct QueueButton: View {
    let player: PlayerEngine
    @State private var showQueue = false

    var body: some View {
        Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }
            .buttonStyle(.borderless)
            .popover(isPresented: $showQueue, arrowEdge: .bottom) {
                QueueView(player: player)
            }
    }
}

struct QueueView: View {
    let player: PlayerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Playing Next")
                .font(.headline)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

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
        }
        .frame(width: 360, height: 460)
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
