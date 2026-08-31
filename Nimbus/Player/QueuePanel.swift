import NukeUI
import SwiftUI

struct QueueButton: View {
    @Binding var isVisible: Bool

    var body: some View {
        Button { isVisible.toggle() } label: { Image(systemName: "list.bullet") }
            .foregroundStyle(isVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
}

/// Queue as a trailing inspector column: it takes room from the detail view rather than covering it,
/// which is how Music's Playing Next behaves — the content reflows, nothing is hidden underneath.
struct QueuePanel: View {
    static let rowHeight: CGFloat = 52

    let player: PlayerEngine
    let onClose: () -> Void
    /// Lets a #Preview render the dragging state, which has no pointer to produce it.
    var previewDrag: (id: Int, y: CGFloat)? = nil

    private static let contentSpace = "queueContent"
    private static let listPadding: CGFloat = 4

    /// Row being dragged and where the pointer is inside the list's own content. Tracking the
    /// pointer rather than the travelled distance keeps the row under the cursor even while the
    /// list auto-scrolls beneath it.
    @State private var draggingID: Int?
    @State private var pointerY: CGFloat = 0
    @State private var scrollY: CGFloat = 0

    private var upcomingCount: Int {
        max(0, player.queue.count - player.currentIndex - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if player.queue.isEmpty {
                empty
            } else {
                queueList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Playing Next").font(.system(size: 13, weight: .semibold))
                if upcomingCount > 0 {
                    Text("\(upcomingCount) track\(upcomingCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button("Clear") { player.clearUpcoming() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(upcomingCount == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .disabled(upcomingCount == 0)

            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text("Queue is empty").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A plain stack rather than List: List's `.onMove` only reorders once the drag ends, while
    /// Music reflows the rows live under the pointer.
    private var queueList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(player.queue) { track in
                        row(track, proxy: proxy)
                            .id(track.id)
                    }
                }
                .padding(.vertical, Self.listPadding)
                .coordinateSpace(.named(Self.contentSpace))
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offset in
                scrollY = offset
            }
            // The dragged row is drawn here rather than in place: zIndex has no effect inside a
            // LazyVStack, so the row below it painted over the one being carried.
            .overlay(alignment: .top) {
                if let track = draggedTrack {
                    QueueItemView(
                        track: track,
                        player: player,
                        isCurrent: track.id == player.currentTrack?.id,
                        isDragging: true,
                        onJump: {})
                    .frame(height: Self.rowHeight)
                    .scaleEffect(1.02)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .offset(y: activePointerY - scrollY - Self.rowHeight / 2)
                    .allowsHitTesting(false)
                }
            }
            .task(id: player.currentTrack?.id) {
                guard draggingID == nil, let id = player.currentTrack?.id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var activeDragID: Int? { draggingID ?? previewDrag?.id }
    private var activePointerY: CGFloat { draggingID != nil ? pointerY : (previewDrag?.y ?? 0) }

    private func row(_ track: SCTrack, proxy: ScrollViewProxy) -> some View {
        let isDragging = activeDragID == track.id
        return QueueItemView(
            track: track,
            player: player,
            isCurrent: track.id == player.currentTrack?.id,
            isDragging: isDragging,
            onJump: { jump(to: track) },
            onRemove: { remove(track) })
        .frame(height: Self.rowHeight)
        // Leaves the gap the other rows open around, while the row itself rides in the overlay.
        .opacity(isDragging ? 0 : 1)
        .gesture(dragGesture(track, proxy: proxy))
    }

    private var draggedTrack: SCTrack? {
        guard let id = activeDragID else { return nil }
        return player.queue.first { $0.id == id }
    }

    private func dragGesture(_ track: SCTrack, proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.contentSpace))
            .onChanged { value in
                guard let index = player.queue.firstIndex(where: { $0.id == track.id }) else { return }
                draggingID = track.id
                pointerY = value.location.y

                let row = (pointerY - Self.listPadding) / Self.rowHeight
                let target = min(max(Int(row), 0), player.queue.count - 1)
                guard target != index else { return }
                withAnimation(.snappy(duration: 0.18)) {
                    player.moveInQueue(from: IndexSet(integer: index),
                                       to: target > index ? target + 1 : target)
                }
                // Keeps a long queue reachable: dragging alone never scrolls the list, so the row
                // could only travel as far as the visible part of the panel.
                proxy.scrollTo(track.id)
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.18)) { draggingID = nil }
            }
    }

    private func jump(to track: SCTrack) {
        guard let index = player.queue.firstIndex(where: { $0.id == track.id }) else { return }
        Task { await player.jump(to: index) }
    }

    private func remove(_ track: SCTrack) {
        guard let index = player.queue.firstIndex(where: { $0.id == track.id }) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            player.removeFromQueue(atOffsets: IndexSet(integer: index))
        }
    }
}

struct QueueItemView: View {
    let track: SCTrack
    let player: PlayerEngine
    let isCurrent: Bool
    var isDragging = false
    let onJump: () -> Void
    var onRemove: () -> Void = {}

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
                    if hovering && !isDragging {
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

            Button(action: onRemove) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .opacity(hovering && !isDragging ? 1 : 0)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .opacity(hovering || isDragging ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                // Opaque while carried: a translucent fill lets the row underneath read straight
                // through the one being dragged.
                .fill(isDragging
                      ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                      : AnyShapeStyle(Color.primary.opacity(hovering ? 0.05 : 0)))
                .overlay {
                    if isDragging {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .padding(.horizontal, 6)
        }
        .contentShape(Rectangle())
        .trackContextMenu(track, player: player)
        .onHover { hovering = $0 }
    }
}
