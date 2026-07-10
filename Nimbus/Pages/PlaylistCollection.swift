import SwiftUI

/// One page for each of the three things `/me/library/all` already distinguishes.
struct PlaylistCollection: View {
    let section: LibrarySection
    let library: LibraryStore

    private var playlists: [SCPlaylist] {
        switch section {
        case .albums: library.albums
        case .stations: library.stations
        default: library.userPlaylists
        }
    }

    private var emptyMessage: String {
        switch section {
        case .albums: "Albums you like or repost appear here."
        case .stations: "SoundCloud's mixes and stations you save appear here."
        default: "Playlists you create, like or repost appear here."
        }
    }

    var body: some View {
        List(playlists) { playlist in
            NavigationLink(value: playlist) {
                PlaylistRow(playlist: playlist)
            }
        }
        .listStyle(.inset)
        .overlay {
            if library.isLoadingPlaylists && library.playlists.isEmpty {
                ProgressView().controlSize(.small)
            } else if playlists.isEmpty {
                ContentUnavailableView("No \(section.rawValue.lowercased())",
                    systemImage: section.systemImage,
                    description: Text(emptyMessage))
            }
        }
        .navigationTitle(section.rawValue)
        .task { library.loadPlaylistsIfNeeded() }
    }
}
