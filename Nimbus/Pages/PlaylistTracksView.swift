import NukeUI
import SwiftUI

struct PlaylistTracksView: View {
    let playlist: SCPlaylist
    let library: LibraryStore
    let player: PlayerEngine

    @State private var tracks: [SCTrack] = []
    @State private var isLoading = true
    @State private var loadError: String?


    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                PlaylistHeader(playlist: playlist, tracks: tracks, player: player)
                    .padding(.bottom, 16)

                ForEach(tracks) { track in
                    TrackRow(track: track, player: player, queueContext: tracks)
                }
                if isLoading {
                    ProgressView().controlSize(.small).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle(playlist.title)
        .overlay {
            if let loadError, tracks.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tracks = try await library.tracks(for: playlist)
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }
}

struct PlaylistHeader: View {
    let playlist: SCPlaylist
    let tracks: [SCTrack]
    let player: PlayerEngine

    private var kindLabel: String {
        playlist.isAlbum ? "Album" : playlist.isSystem ? "Mix" : "Playlist"
    }

    private var summary: String {
        let count = tracks.isEmpty ? playlist.trackCount : tracks.count
        let ms = tracks.isEmpty ? (playlist.duration ?? 0) : tracks.reduce(0) { $0 + $1.duration }
        var parts = ["\(count) tracks"]
        if ms > 0 { parts.append(longDurationString(ms: ms)) }
        return parts.joined(separator: " · ")
    }

    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            LazyImage(url: playlist.artworkURL.scArtwork()) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: metrics.pageArtwork, height: metrics.pageArtwork)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(kindLabel.uppercased())
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                Text(playlist.title).font(.largeTitle).bold().lineLimit(2)
                if let user = playlist.user {
                    NavigationLink(value: user) {
                        Text(user.username).font(.subheadline).foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
                Text(summary).font(.caption).foregroundStyle(.secondary)
                if let description = playlist.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button {
                        guard let first = tracks.first else { return }
                        Task { await player.play(first, in: tracks) }
                    } label: {
                        Label("Play", systemImage: "play.fill").frame(minWidth: 76)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { await player.playShuffled(tracks) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(minWidth: 76)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(tracks.isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}
