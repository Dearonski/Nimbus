import SwiftUI

/// The social half of SoundCloud, given its own destination instead of being buried at the
/// bottom of Home: posts and reposts from the people you follow.
struct FeedView: View {
    let model: AppModel

    private var items: [SCStreamItem] { model.library.stream }
    private var tracks: [SCTrack] {
        items.compactMap { if case .track(let t) = $0.content { t } else { nil } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    StreamItemView(item: item, model: model, context: tracks)
                        .onAppear {
                            if item.id == items.last?.id {
                                Task { await model.library.loadMoreStream() }
                            }
                        }
                    if item.id != items.last?.id {
                        Divider().opacity(0.4).padding(.horizontal, 24)
                    }
                }
                if model.library.isLoadingStream {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .padding(.vertical, 20)
                }
            }
            .padding(.vertical, 12)
        }
        .overlay {
            if items.isEmpty && !model.library.isLoadingStream {
                ContentUnavailableView("Nothing here yet", systemImage: "newspaper",
                    description: Text("Follow some artists and their posts show up here."))
            }
        }
        .navigationTitle("Feed")
        .task { model.library.loadStreamIfNeeded() }
    }
}

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

struct FollowingView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 20)], spacing: 24) {
                ForEach(model.library.following) { artist in
                    ArtistCircle(artist: artist)
                }
            }
            .padding(24)
        }
        .overlay {
            if model.library.following.isEmpty {
                if model.library.isLoadingFollowing {
                    ProgressView().controlSize(.small)
                } else {
                    ContentUnavailableView("Not following anyone", systemImage: "person.2",
                        description: Text("Artists you follow appear here."))
                }
            }
        }
        .navigationTitle("Following")
        .task { model.library.loadFollowingIfNeeded() }
    }
}
