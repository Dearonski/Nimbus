import SwiftUI

/// The column beside a track: who made it, how it is doing, who plays it most, and where else it
/// appears. Same blocks and same order as the web client.
struct TrackRail: View {
    let page: TrackPageModel
    let model: AppModel

    private var artist: SCUser { page.author ?? page.track.user }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            RailArtistCard(artist: artist, model: model)
            StatTiles.track(page.track)
            if let fans = page.fans { FanBoard(fans: fans) }
            if !page.related.isEmpty {
                RailBlock(title: "Related tracks") {
                    VStack(spacing: 2) {
                        ForEach(page.related.prefix(5)) { RelatedRow(track: $0, model: model) }
                    }
                }
            }
            if !page.playlists.isEmpty {
                RailBlock(title: "In playlists") { SetGrid(sets: page.playlists) }
            }
            if !page.albums.isEmpty {
                RailBlock(title: "In albums") { SetGrid(sets: page.albums) }
            }
        }
    }
}

/// Who made it, with the follow control right there — the card that opens the column beside a
/// track or a set.
struct RailArtistCard: View {
    let artist: SCUser
    let model: AppModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                NavButton(value: artist) {
                    Artwork(artist, size: .mid)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    NavButton(value: artist) {
                        HStack(spacing: 5) {
                            Text(artist.username)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            if artist.verified == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if let city = artist.city, !city.isEmpty {
                        Text(city).font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    Text("\(countString(artist.followersCount ?? 0)) followers · "
                         + "\(countString(artist.trackCount ?? 0)) tracks")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                let isFollowing = model.library.isFollowing(artist)
                Button { model.library.toggleFollow(artist) } label: {
                    Label(isFollowing ? "Following" : "Follow",
                          systemImage: isFollowing ? "checkmark" : "plus")
                        .frame(maxWidth: .infinity)
                }
                .glassButton(.prominent)

                if let messages = messagesURL {
                    Button { openURL(messages) } label: {
                        Label("Message", systemImage: "envelope").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
            }
            .glassButtonRow()
        }
        .padding(16)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
    }

    private var messagesURL: URL? {
        guard let permalink = artist.permalinkURL?.split(separator: "/").last, !permalink.isEmpty
        else { return nil }
        return URL(string: "https://soundcloud.com/messages/\(permalink)")
    }
}

/// The leaderboard the gateway calls `topFans`: who played this track the most, all time or over
/// its first days.
private struct FanBoard: View {
    let fans: SCTopFans

    @State private var showsFirstPeriod = false

    private var rows: [SCTopFans.Fan] { showsFirstPeriod ? fans.firstPeriod : fans.allTime }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("FANS")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                HStack(spacing: 12) {
                    tab("Top", selected: !showsFirstPeriod) { showsFirstPeriod = false }
                    if !fans.firstPeriod.isEmpty {
                        tab("First \(fans.firstPeriodDays) days", selected: showsFirstPeriod) {
                            showsFirstPeriod = true
                        }
                    }
                }
            }

            Text("Who has played this track the most")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, fan in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, alignment: .trailing)

                    NavButton(value: fan.user) {
                        HStack(spacing: 10) {
                            Artwork(fan.user, size: .thumb)
                                .frame(width: 28, height: 28)
                                .clipShape(Circle())
                            Text(fan.user.username)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    Text("\(fan.plays.formatted(.number.locale(Locale(identifier: "en_US")))) plays")
                        .font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
    }
}

private struct RelatedRow: View {
    let track: SCTrack
    let model: AppModel

    var body: some View {
        NavButton(value: track) {
            HStack(spacing: 10) {
                Artwork(track, size: .thumb)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(track.user.username).lineLimit(1)
                        Label(countString(track.playbackCount ?? 0), systemImage: "play.fill")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .trackContextMenu(track, player: model.player)
    }
}

/// Sets appear as a row of covers rather than a list — the web client's own shape, and it fits
/// three in the width a single row would waste.
private struct SetGrid: View {
    let sets: [SCPlaylist]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 12) {
            ForEach(sets.prefix(6)) { playlist in
                NavButton(value: playlist) {
                    VStack(alignment: .leading, spacing: 5) {
                        Artwork(playlist, size: .mid)
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(playlist.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#if DEBUG
#Preview("Track rail") {
    let model = AppModel()
    let decoder = JSONDecoder()
    let track = try! decoder.decode(SCTrack.self, from: Data("""
    {"id":1,"title":"6AM в Будапеште","duration":183224,"permalink_url":"x","artwork_url":null,
     "user":{"id":9,"username":"OG Buda","verified":true,"city":"Tyumen",
             "followers_count":35419,"track_count":257},
     "media":{"transcodings":[]},"track_authorization":"",
     "playback_count":6268472,"likes_count":90726,"reposts_count":262,"comment_count":522}
    """.utf8))
    let related = (1...4).map { index in
        try! decoder.decode(SCTrack.self, from: Data("""
        {"id":\(100 + index),"title":"Related track \(index)","duration":190000,"permalink_url":"x",
         "artwork_url":null,"user":{"id":\(index),"username":"hardglock"},
         "media":{"transcodings":[]},"track_authorization":"","playback_count":\(index * 1_200_000)}
        """.utf8))
    }
    let sets = (1...3).map { index in
        try! decoder.decode(SCPlaylist.self, from: Data("""
        {"id":\(index),"title":"Playlist \(index)","artwork_url":null,"track_count":\(index * 12),
         "is_album":false,"user":{"id":5,"username":"someone"},"tracks":[]}
        """.utf8))
    }
    let fanUsers = ["vladrozovv", "ye6an", "SoundC1aus", "wnixy", "Qko"].enumerated().map { index, name in
        try! decoder.decode(SCUser.self, from: Data("""
        {"id":\(200 + index),"username":"\(name)","avatar_url":null,"permalink_url":"x"}
        """.utf8))
    }
    let plays = [1115, 1039, 922, 661, 659]
    let board = SCTopFans(firstPeriodDays: 7,
                          allTime: zip(fanUsers, plays).map { .init(user: $0, plays: $1) },
                          firstPeriod: zip(fanUsers.reversed(), [346, 124, 52, 44, 39]).map {
                              .init(user: $0, plays: $1)
                          })

    let page = TrackPageModel(track: track, api: model.api)
    page.seedForPreview(fans: board, related: related, playlists: sets, author: track.user)

    return ScrollView {
        TrackRail(page: page, model: model)
            .frame(width: 336)
            .padding(24)
    }
    .environment(model.library)
    .frame(width: 420, height: 900)
    .tint(.scOrange)
}
#endif
