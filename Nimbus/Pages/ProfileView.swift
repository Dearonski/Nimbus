import NukeUI
import SwiftUI

struct ProfileView: View {
    let model: AppModel
    @Binding var section: LibrarySection?

    @State private var uploads: [SCTrack] = []

    private var likes: [SCTrack] { model.library.likes.tracks }
    private var playlists: [SCPlaylist] { model.library.playlists }

    var body: some View {
        ScrollView {
            if let me = model.library.meUser {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ProfileHeader(user: me)

                    if !likes.isEmpty {
                        HomeCarousel(title: "Likes", items: Array(likes.prefix(20)),
                                     seeAll: { section = .likes }) { track in
                            TrackCard(track: track, player: model.player, context: likes)
                        }
                    }
                    if !playlists.isEmpty {
                        HomeCarousel(title: "Playlists", items: Array(playlists.prefix(20)),
                                     seeAll: { section = .playlists }) { playlist in
                            PlaylistCard(playlist: playlist, model: model)
                        }
                    }
                    if !uploads.isEmpty {
                        HomeCarousel(title: "Tracks", items: uploads) { track in
                            TrackCard(track: track, player: model.player, context: uploads)
                        }
                    }
                }
                .padding(.vertical, 16)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .navigationTitle("Profile")
        .task {
            model.library.loadMe()
            model.library.likes.loadInitialIfNeeded()
            model.library.loadPlaylistsIfNeeded()
        }
        .task(id: model.library.meUser?.id) {
            guard let me = model.library.meUser, uploads.isEmpty else { return }
            uploads = (try? await model.api.userTracks(id: me.id))?.collection ?? []
        }
    }
}

struct ProfileHeader: View {
    let user: SCUser

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            LazyImage(url: user.avatarURL.scArtwork()) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 128, height: 128)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(user.username).font(.largeTitle).bold().lineLimit(1)
                    if user.verified == true {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint)
                    }
                }
                HStack(spacing: 28) {
                    stat(user.followersCount ?? 0, "Followers")
                    stat(user.followingsCount ?? 0, "Following")
                    stat(user.trackCount ?? 0, "Tracks")
                }
                if let city = user.city, !city.isEmpty {
                    Label(city, systemImage: "mappin.and.ellipse")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(countString(value)).font(.headline).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
