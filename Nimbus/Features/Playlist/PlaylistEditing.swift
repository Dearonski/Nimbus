import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A context menu has no view to hang a sheet on, so the sheet goes on the shell window itself.
@MainActor
enum ShellSheet {
    private static var open: Set<NSWindow> = []

    static func present<Content: View>(_ content: (_ close: @escaping () -> Void) -> Content) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let close = { [weak window] in
            guard let window else { return }
            if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
            open.remove(window)
        }
        let host = NSHostingController(rootView: content(close))
        // Measured once and fixed: a window sizing itself to the hosting view mid-layout threw from AppKit.
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(host.sizeThatFits(in: CGSize(width: 2000, height: 2000)))
        open.insert(window)

        if let parent = NSApp.windows.first(where: { $0.isVisible && $0.contentViewController is ShellSplitController }) {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
func createEmptyPlaylist(_ model: AppModel) {
    ShellSheet.present { close in
        NewPlaylistSheet(cover: nil, close: close) { title, isPrivate in
            let made = try await model.library.createPlaylist(title: title, isPrivate: isPrivate, with: [])
            close()
            model.shell?.open(made)
        }
    }
}

struct AddToPlaylistMenu: View {
    let track: SCTrack
    let player: PlayerEngine

    @Environment(LibraryStore.self) private var library: LibraryStore?

    var body: some View {
        if let library, library.meUser != nil {
            Menu("Add to Playlist", systemImage: "text.badge.plus") {
                Button("New Playlist…") { create(in: library) }
                let own = library.ownPlaylists
                if !own.isEmpty { Divider() }
                ForEach(own) { playlist in
                    // Only known when the library listed the set's tracks; otherwise adding twice is caught on the way.
                    if playlist.trackIDs.contains(track.id) {
                        Button(playlist.title, systemImage: "checkmark") {}.disabled(true)
                    } else {
                        Button(playlist.title) { add(to: playlist, in: library) }
                    }
                }
            }
            .disabled(!track.isPlayable)
        }
    }

    private func create(in library: LibraryStore) {
        let track = track
        ShellSheet.present { close in
            NewPlaylistSheet(cover: track, close: close) { title, isPrivate in
                _ = try await library.createPlaylist(title: title, isPrivate: isPrivate, with: [track])
                close()
            }
        }
    }

    private func add(to playlist: SCPlaylist, in library: LibraryStore) {
        Task {
            do {
                if try await !library.add(track, to: playlist) {
                    player.report("“\(track.title)” is already in “\(playlist.title)”")
                }
            } catch {
                player.report("Couldn't add to “\(playlist.title)”: \(error.surfaced())")
            }
        }
    }
}

// Lets a track's menu take it out of the playlist page it is listed on; set only on your own.
@MainActor
struct PlaylistTrackRemoval: Equatable {
    let remove: (SCTrack) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var playlistTrackRemoval: PlaylistTrackRemoval?
}

private struct PlaylistCover<Image: View>: View {
    @ViewBuilder var image: Image

    var body: some View {
        image
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary)
            }
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

private struct EmptyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note.list")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}

private struct PrivacyToggle: View {
    @Binding var isPrivate: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Private")
                Text("Only you and people with the link can see it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Private", isOn: $isPrivate)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.scOrange)
        }
    }
}

private struct SheetFooter<Leading: View>: View {
    let action: String
    let canSubmit: Bool
    let isWorking: Bool
    let error: String?
    let cancel: () -> Void
    let submit: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                leading
            }
            Spacer(minLength: 12)
            if isWorking { ProgressView().controlSize(.small) }
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(action, action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isWorking)
        }
        .controlSize(.large)
    }
}

struct NewPlaylistSheet: View {
    let cover: SCTrack?
    let close: () -> Void
    let create: (_ title: String, _ isPrivate: Bool) async throws -> Void

    @State private var title = ""
    @State private var isPrivate = true
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 18) {
                PlaylistCover {
                    if let cover { Artwork(cover, size: .mid) } else { EmptyCover() }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("New Playlist").font(.title3.bold())
                    TextField("Playlist Name", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($titleFocused)
                        .onSubmit(submit)
                    if let cover {
                        Text("Starts with “\(cover.title)”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            PrivacyToggle(isPrivate: $isPrivate)
            SheetFooter(action: "Create", canSubmit: !trimmed.isEmpty, isWorking: isWorking, error: error,
                        cancel: close, submit: submit) { EmptyView() }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { titleFocused = true }
    }

    private func submit() {
        guard !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        error = nil
        let title = trimmed
        Task {
            do {
                try await create(title, isPrivate)
            } catch {
                isWorking = false
                self.error = "Couldn't create “\(title)”: \(error.surfaced())"
            }
        }
    }
}

// Title, description, privacy and the order of the tracks, saved in one go as the site does.
struct PlaylistEditor: View {
    let page: PlaylistPageModel
    let library: LibraryStore

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var details: String
    @State private var isPrivate: Bool
    @State private var rows: [Row]
    @State private var isSaving = false
    @State private var error: String?
    @State private var dragging: UUID?

    init(page: PlaylistPageModel, library: LibraryStore) {
        self.page = page
        self.library = library
        let playlist = page.playlist
        _title = State(initialValue: playlist.title)
        _details = State(initialValue: playlist.description ?? "")
        _isPrivate = State(initialValue: playlist.isPrivate)
        let known = Dictionary(page.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = playlist.trackIDs.isEmpty ? page.tracks.map(\.id) : playlist.trackIDs
        _rows = State(initialValue: ids.map { Row(trackID: $0, track: known[$0]) })
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    PlaylistCover { Artwork(page.playlist, size: .mid) }
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Playlist Name", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                        TextField("Description (Optional)", text: $details, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3, reservesSpace: true)
                    }
                }
                PrivacyToggle(isPrivate: $isPrivate)
            }
            .padding(24)

            Divider()
            tracks
            Divider()

            SheetFooter(action: "Save", canSubmit: !trimmedTitle.isEmpty, isWorking: isSaving, error: error,
                        cancel: { dismiss() }, submit: save) {
                Text("^[\(rows.count) track](inflect: true) · drag to reorder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 540, height: 640)
    }

    // SwiftUI's List trapped in its outline diff on these rows (macOS 27), so the order is dragged by hand.
    private var tracks: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    TrackEditRow(index: index + 1, track: row.track, isStriped: index.isMultiple(of: 2)) {
                        withAnimation(.snappy) { rows.removeAll { $0.id == row.id } }
                    }
                    .opacity(dragging == row.id ? 0.35 : 1)
                    .onDrag {
                        dragging = row.id
                        return NSItemProvider(object: row.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: RowDrop(target: row.id, rows: $rows, dragging: $dragging))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            dragging = nil
            return true
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No Tracks", systemImage: "music.note.list",
                                       description: Text("Add tracks from any track’s menu."))
            }
        }
    }

    private func save() {
        isSaving = true
        error = nil
        let playlist = page.playlist
        let title = trimmedTitle
        let details = details
        let isPrivate = isPrivate
        let ids = rows.map(\.trackID)
        Task {
            do {
                try await library.save(playlist, title: title, description: details, isPrivate: isPrivate,
                                       trackIDs: ids)
                dismiss()
            } catch {
                isSaving = false
                self.error = "Couldn't save: \(error.surfaced())"
            }
        }
    }
}

// A set can hold a track twice, and one SoundCloud no longer serves still has its place.
private struct Row: Identifiable {
    let id = UUID()
    let trackID: Int
    let track: SCTrack?
}

private struct RowDrop: DropDelegate {
    let target: UUID
    @Binding var rows: [Row]
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = rows.firstIndex(where: { $0.id == dragging }),
              let to = rows.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.snappy) { rows.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct TrackEditRow: View {
    let index: Int
    let track: SCTrack?
    let isStriped: Bool
    let remove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            Artwork(track, size: .thumb)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(track?.title ?? "Unavailable track").lineLimit(1)
                Text(track?.user.username ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                if let track {
                    Text(timeString(Double(track.duration) / 1000))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 0 : 1)
                }
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill").font(.body).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from Playlist")
                .opacity(isHovered ? 1 : 0)
            }
            .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(isHovered ? 0.07 : isStriped ? 0.03 : 0))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

@MainActor
enum PlaylistDeletion {
    static func confirm(_ playlist: SCPlaylist) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete “\(playlist.title)”?"
        alert.informativeText = "The playlist is removed from SoundCloud for everyone. The tracks in it stay."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}

#if DEBUG
#Preview("New playlist") {
    NewPlaylistSheet(cover: nil, close: {}) { _, _ in }
}

#Preview("Edit playlist") {
    let model = AppModel()
    let playlist = try! JSONDecoder().decode(SCPlaylist.self, from: Data("""
    {"id":1891647005,"title":"Late Night Drive","kind":"playlist","track_count":3,"sharing":"private",
     "description":"Slow synths for empty roads.","permalink_url":"https://soundcloud.com/x/sets/late",
     "user":{"id":9,"username":"kirill"},"tracks":[]}
    """.utf8))
    let page = PlaylistPageModel(playlist: playlist, api: model.api, library: model.library)
    page.seedForPreview(tracks: [previewStripTrack(comments: 0), previewStripTrack(comments: 0)])
    return PlaylistEditor(page: page, library: model.library)
}
#endif
