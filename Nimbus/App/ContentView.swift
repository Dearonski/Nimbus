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
        .frame(minWidth: 900, minHeight: 600)
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
                ForEach(LibrarySection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .navigationTitle("Nimbus")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                if searchText.isEmpty {
                    switch section {
                    case .likes, .none:
                        TrackList(feed: model.library.likes, player: model.player)
                    case .history:
                        TrackList(feed: model.library.history, player: model.player)
                    case .playlists:
                        ContentUnavailableView("Coming soon", systemImage: "music.note.list",
                            description: Text("Playlists land later in M1."))
                    }
                } else {
                    SearchResults(tracks: model.library.searchResults, player: model.player)
                }
                Divider()
                NowPlayingBar(player: model.player)
            }
            .searchable(text: $searchText, prompt: "Search library")
            .onChange(of: searchText) { _, query in model.library.search(query) }
        }
    }
}

struct TrackList: View {
    let feed: TrackFeed
    let player: PlayerEngine

    var body: some View {
        List {
            ForEach(feed.tracks) { track in
                TrackRow(track: track) { Task { await player.play(track) } }
                    .onAppear {
                        if track.id == feed.tracks.last?.id {
                            Task { await feed.loadMore() }
                        }
                    }
            }
            if feed.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .listStyle(.inset)
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
            List(tracks) { track in
                TrackRow(track: track) { Task { await player.play(track) } }
            }
            .listStyle(.inset)
        }
    }
}

struct TrackRow: View {
    let track: SCTrack
    let play: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            LazyImage(url: track.artworkURL.flatMap(URL.init)) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(track.user.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: play)
    }
}

struct NowPlayingBar: View {
    let player: PlayerEngine

    var body: some View {
        HStack(spacing: 10) {
            if let track = player.currentTrack {
                LazyImage(url: track.artworkURL.flatMap(URL.init)) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).lineLimit(1)
                    Text(track.user.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Nothing playing").foregroundStyle(.secondary)
            }

            Spacer()

            Text(player.status).font(.caption).foregroundStyle(.secondary)
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28)
            }
            .buttonStyle(.borderless)
            .disabled(player.currentTrack == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 56)
    }
}

#Preview {
    ContentView()
}
