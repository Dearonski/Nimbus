import AVFoundation
import NukeUI
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        Group {
            if model.isAuthenticated {
                LibraryShell(model: model)
            } else {
                LoginWebView { _ in model.didAuthenticate() }
            }
        }
        .frame(minWidth: 1040, minHeight: 620)
        .tint(.scOrange)
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case likes = "Likes"
    case playlists = "Playlists"
    case history = "History"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .likes: "heart"
        case .playlists: "music.note.list"
        case .history: "clock"
        }
    }
}

struct LibraryShell: View {
    let model: AppModel
    @State private var section: LibrarySection? = .likes
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("Library") {
                    ForEach(LibrarySection.allCases) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            Group {
                if searchText.isEmpty {
                    switch section {
                    case .likes, .none:
                        TrackList(feed: model.library.likes, player: model.player)
                    case .history:
                        TrackList(feed: model.library.history, player: model.player)
                    case .playlists:
                        PlaylistsView(library: model.library, player: model.player)
                    }
                } else {
                    SearchResults(tracks: model.library.searchResults, player: model.player)
                }
            }
            .searchable(text: $searchText, prompt: "Search library")
            .onChange(of: searchText) { _, query in model.library.search(query) }
            .safeAreaInset(edge: .bottom) {
                PlayerPill(player: model.player)
            }
        }
    }
}

// MARK: - Floating player pill (Apple Music style, bottom-centered)

struct PlayerPill: View {
    let player: PlayerEngine

    var body: some View {
        PlayerPillContent(
            track: player.currentTrack,
            isPlaying: player.isPlaying,
            currentTime: player.currentTime,
            duration: player.duration,
            isShuffled: player.isShuffled,
            repeatMode: player.repeatMode,
            canPrevious: player.canGoPrevious,
            canNext: player.canGoNext,
            volume: Binding(
                get: { Double(player.player.volume) },
                set: { player.player.volume = Float($0) }),
            onToggle: player.togglePlayPause,
            onSeek: { player.seek(to: $0) },
            onShuffle: player.toggleShuffle,
            onRepeat: player.cycleRepeat,
            onPrevious: { Task { await player.previous() } },
            onNext: { Task { await player.next() } })
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }
}

/// Apple Music-style pill: transport left, now-playing + thin progress center, actions right.
struct PlayerPillContent: View {
    let track: SCTrack?
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    var isShuffled = false
    var repeatMode: RepeatMode = .off
    var canPrevious = false
    var canNext = false
    @Binding var volume: Double
    let onToggle: () -> Void
    let onSeek: (Double) -> Void
    var onShuffle: () -> Void = {}
    var onRepeat: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            transport
            nowPlaying.frame(maxWidth: .infinity)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 3)
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button(action: onShuffle) { Image(systemName: "shuffle") }
                .foregroundStyle(isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Button(action: onPrevious) { Image(systemName: "backward.fill") }
                .disabled(!canPrevious)
            Button(action: onToggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20))
            }
            .disabled(track == nil)
            Button(action: onNext) { Image(systemName: "forward.fill") }
                .disabled(!canNext)
            Button(action: onRepeat) {
                Image(systemName: repeatMode == .one ? "repeat.1" : "repeat")
            }
            .foregroundStyle(repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .font(.system(size: 13))
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }

    private var nowPlaying: some View {
        HStack(spacing: 8) {
            LazyImage(url: track?.artworkURL.flatMap(URL.init)) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(spacing: 3) {
                Text(track?.title ?? "Not Playing")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                ProgressScrubber(currentTime: currentTime, duration: duration, onSeek: onSeek)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Button { } label: { Image(systemName: "ellipsis") }.disabled(true)
            Button { } label: { Image(systemName: "list.bullet") }.disabled(true)
            VolumeButton(volume: $volume)
        }
        .font(.system(size: 13))
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

/// Thin, knob-less progress line (tint-filled) with tap/drag to seek — Apple Music style.
struct ProgressScrubber: View {
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.3))
                Capsule().fill(.tint).frame(width: geo.size.width * fraction)
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    guard duration > 0 else { return }
                    let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                    onSeek(fraction * duration)
                })
        }
        .frame(height: 12)
    }
}

struct VolumeButton: View {
    @Binding var volume: Double
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showPopover) {
            Slider(value: $volume, in: 0...1).frame(width: 120).padding()
        }
    }
}

// MARK: - Track lists

struct TrackTable: View {
    let tracks: [SCTrack]
    let player: PlayerEngine
    var isLoading = false
    var onReachEnd: () async -> Void = {}

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(tracks) { track in
                    TrackRow(track: track, player: player, queueContext: tracks)
                        .onAppear {
                            if track.id == tracks.last?.id { Task { await onReachEnd() } }
                        }
                }
                if isLoading {
                    ProgressView().controlSize(.small).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct TrackList: View {
    let feed: TrackFeed
    let player: PlayerEngine

    var body: some View {
        TrackTable(
            tracks: feed.tracks, player: player, isLoading: feed.isLoading,
            onReachEnd: { await feed.loadMore() })
        .overlay {
            if let error = feed.error, feed.tracks.isEmpty {
                ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            }
        }
        .task { await feed.loadInitialIfNeeded() }
    }
}

struct SearchResults: View {
    let tracks: [SCTrack]
    let player: PlayerEngine

    var body: some View {
        if tracks.isEmpty {
            ContentUnavailableView.search
        } else {
            TrackTable(tracks: tracks, player: player)
        }
    }
}

struct PlaylistsView: View {
    let library: LibraryStore
    let player: PlayerEngine

    var body: some View {
        NavigationStack {
            List(library.playlists) { playlist in
                NavigationLink(value: playlist) {
                    PlaylistRow(playlist: playlist)
                }
            }
            .listStyle(.inset)
            .navigationDestination(for: SCPlaylist.self) { playlist in
                PlaylistTracksView(playlist: playlist, library: library, player: player)
            }
            .overlay {
                if library.playlists.isEmpty {
                    ContentUnavailableView("No playlists", systemImage: "music.note.list",
                        description: Text("Playlists and system mixes you save appear here."))
                }
            }
            .task { await library.loadPlaylistsIfNeeded() }
        }
    }
}

struct PlaylistRow: View {
    let playlist: SCPlaylist

    var body: some View {
        HStack(spacing: 10) {
            LazyImage(url: playlist.artworkURL.flatMap(URL.init)) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).lineLimit(1)
                Text("\(playlist.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PlaylistTracksView: View {
    let playlist: SCPlaylist
    let library: LibraryStore
    let player: PlayerEngine

    @State private var tracks: [SCTrack] = []
    @State private var isLoading = true

    var body: some View {
        TrackTable(tracks: tracks, player: player)
            .overlay {
                if isLoading { ProgressView().controlSize(.small) }
            }
            .navigationTitle(playlist.title)
            .task {
                tracks = await library.tracks(for: playlist)
                isLoading = false
            }
    }
}

struct TrackRow: View {
    let track: SCTrack
    let player: PlayerEngine
    var queueContext: [SCTrack] = []

    @State private var hovering = false

    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                HStack(spacing: 6) {
                    Text(track.user.username)
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    if let genre = track.genre, !genre.isEmpty {
                        GenreBadge(text: genre)
                    }
                }
            }

            Spacer()

            stats

            Text(timeString(Double(track.duration) / 1000))
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
                .opacity(hovering ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { play() }
    }

    private var artwork: some View {
        Button(action: artworkTapped) {
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
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(.white).font(.system(size: 18))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var stats: some View {
        HStack(spacing: 16) {
            stat("play.fill", track.playbackCount)
            stat("heart.fill", track.likesCount)
            stat("text.bubble.fill", track.commentCount)
            stat("arrow.2.squarepath", track.repostsCount)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func stat(_ symbol: String, _ count: Int?) -> some View {
        if let count, count > 0 {
            HStack(spacing: 4) {
                Image(systemName: symbol).imageScale(.small)
                Text(countString(count)).monospacedDigit()
            }
        }
    }

    private func artworkTapped() {
        if isCurrent { player.togglePlayPause() } else { play() }
    }

    private func play() {
        Task { await player.play(track, in: queueContext.isEmpty ? [track] : queueContext) }
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

func countString(_ n: Int) -> String {
    let value: Double
    let suffix: String
    if n >= 1_000_000 { value = Double(n) / 1_000_000; suffix = "M" }
    else if n >= 1_000 { value = Double(n) / 1_000; suffix = "K" }
    else { return "\(n)" }
    return (value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)) + suffix
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

#Preview {
    ContentView()
}
