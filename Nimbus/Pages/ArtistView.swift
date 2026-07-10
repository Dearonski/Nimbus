import NukeUI
import SwiftUI

enum ArtistTab: String, CaseIterable, Identifiable {
    case popular = "Popular"
    case tracks = "Tracks"
    case albums = "Albums"
    case playlists = "Playlists"
    case reposts = "Reposts"

    var id: String { rawValue }
}

struct ArtistView: View {
    let user: SCUser
    let model: AppModel

    @State private var tab: ArtistTab = .popular
    @State private var popular: [SCTrack] = []
    @State private var tracks: [SCTrack] = []
    @State private var tracksNextHref: String?
    @State private var albums: [SCPlaylist] = []
    @State private var playlists: [SCPlaylist] = []
    @State private var reposts: [SCStreamItem] = []
    @State private var loadedTabs: Set<ArtistTab> = []
    @State private var isLoading = false

    private var repostTracks: [SCTrack] {
        reposts.compactMap { if case .track(let t) = $0.content { t } else { nil } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if let banner = user.bannerURL.flatMap(URL.init) {
                    LazyImage(url: banner) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.1)
                        }
                    }
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 4)
                }

                ArtistHeader(user: user)
                    .padding(.bottom, 8)

                Picker("", selection: $tab) {
                    ForEach(ArtistTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.bottom, 10)

                tabContent

                if isLoading {
                    ProgressView().controlSize(.small).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle(user.username)
        .task(id: tab) { await load(tab) }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .popular:
            trackRows(popular, empty: "No tracks yet")
        case .tracks:
            ForEach(tracks) { track in
                TrackRow(track: track, player: model.player, queueContext: tracks)
                    .onAppear {
                        if track.id == tracks.last?.id { Task { await loadMoreTracks() } }
                    }
            }
            emptyNote(show: tracks.isEmpty, "No tracks yet")
        case .albums:
            playlistRows(albums, empty: "No albums yet")
        case .playlists:
            playlistRows(playlists, empty: "No playlists yet")
        case .reposts:
            ForEach(reposts) { item in
                StreamItemView(item: item, model: model, context: repostTracks)
            }
            emptyNote(show: reposts.isEmpty, "No reposts yet")
        }
    }

    @ViewBuilder
    private func trackRows(_ items: [SCTrack], empty: String) -> some View {
        ForEach(items) { track in
            TrackRow(track: track, player: model.player, queueContext: items)
        }
        emptyNote(show: items.isEmpty, empty)
    }

    @ViewBuilder
    private func playlistRows(_ items: [SCPlaylist], empty: String) -> some View {
        ForEach(items) { playlist in
            NavigationLink(value: playlist) { PlaylistRow(playlist: playlist) }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        emptyNote(show: items.isEmpty, empty)
    }

    @ViewBuilder
    private func emptyNote(show: Bool, _ text: String) -> some View {
        if show && !isLoading && loadedTabs.contains(tab) {
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
        }
    }

    private func load(_ tab: ArtistTab) async {
        guard !loadedTabs.contains(tab) else { return }
        isLoading = true
        defer {
            isLoading = false
            loadedTabs.insert(tab)
        }
        switch tab {
        case .popular:
            popular = (try? await model.api.userTopTracks(id: user.id))?.collection ?? []
        case .tracks:
            let page = try? await model.api.userTracks(id: user.id)
            tracks = page?.collection ?? []
            tracksNextHref = page?.nextHref
        case .albums:
            albums = (try? await model.api.userAlbums(id: user.id)) ?? []
        case .playlists:
            playlists = (try? await model.api.userPlaylists(id: user.id)) ?? []
        case .reposts:
            reposts = (try? await model.api.userReposts(id: user.id))?.collection ?? []
        }
    }

    private func loadMoreTracks() async {
        guard let href = tracksNextHref else { return }
        tracksNextHref = nil
        let page = try? await model.api.nextTrackPage(href)
        tracks.append(contentsOf: page?.collection ?? [])
        tracksNextHref = page?.nextHref
    }
}

struct ArtistHeader: View {
    let user: SCUser

    var body: some View {
        HStack(spacing: 16) {
            LazyImage(url: user.avatarURL.scArtwork()) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(user.username).font(.title2).bold().lineLimit(1)
                    if user.verified == true {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint)
                    }
                }
                HStack(spacing: 12) {
                    Label(countString(user.followersCount ?? 0), systemImage: "person.2.fill")
                    Label("\(user.trackCount ?? 0) tracks", systemImage: "music.note")
                    if let city = user.city, !city.isEmpty {
                        Label(city, systemImage: "mappin.and.ellipse")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let description = user.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer()
        }
        .padding(12)
    }
}
