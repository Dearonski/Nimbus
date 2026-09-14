import AppKit
import SwiftUI

/// The column the site keeps to the right of an artist's posts: who they are, what they liked, who
/// their listeners also follow, and a strip of their followers. Every block loads on its own and
/// simply doesn't appear when the artist has nothing there.
///
/// Your own page swaps the last two blocks, exactly as the site does: "fans also like" and a wall
/// of your followers say nothing to you, so the column carries who you follow and what you have
/// been saying on other people's tracks instead.
struct ArtistRail: View {
    /// `column` is the 320-wide rail beside the posts; `sections` is the same blocks stacked under
    /// them on a window too narrow to hold both, where a list of three can spread across the width.
    enum Layout { case column, sections }

    let user: SCUser
    let model: AppModel
    var layout: Layout = .column
    var isMe = false

    @State private var likes: [SCLikeItem] = []
    @State private var related: [SCUser] = []
    @State private var followers: [SCUser] = []
    @State private var comments: [SCUserComment] = []
    /// "Fans also like" shows three of the twelve fetched; Refresh walks the window rather than
    /// asking again — the endpoint answers with the same set anyway.
    @State private var relatedOffset = 0
    @State private var loadedID: Int?

    private var isColumn: Bool { layout == .column }
    private var likesShown: Int { isColumn ? 2 : 3 }
    private var relatedShown: Int { isColumn ? 3 : 6 }
    private var facesShown: Int { isColumn ? 8 : 14 }
    private var commentsShown: Int { isColumn ? 3 : 5 }

    private var relatedWindow: [SCUser] {
        guard !related.isEmpty else { return [] }
        return (0..<min(relatedShown, related.count)).map { related[(relatedOffset + $0) % related.count] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if isColumn { ArtistInfoRow(user: user, model: model, stacked: true) }

            if !likes.isEmpty {
                RailBlock(title: "\(countString(user.likesCount ?? likes.count)) likes",
                          action: "View all", destination: ProfileList.likes(user)) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(likes.prefix(likesShown)) { LikeMini(item: $0) }
                    }
                }
            }

            if isMe {
                let following = model.library.following
                if !following.isEmpty {
                    RailBlock(title: "\(countString(user.followingsCount ?? following.count)) following",
                              action: "View all", destination: ProfileList.following(user)) {
                        ArtistFanList(artists: Array(following.prefix(relatedShown)),
                                      library: model.library, wide: !isColumn)
                    }
                }

                if !comments.isEmpty {
                    RailBlock(title: "Latest comments") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(comments.prefix(commentsShown)) { CommentMini(comment: $0) }
                        }
                    }
                }
            } else {
                if !related.isEmpty {
                    RailBlock(title: "Fans also like", action: "Refresh") {
                        relatedOffset = (relatedOffset + relatedShown) % max(related.count, 1)
                    } content: {
                        ArtistFanList(artists: relatedWindow, library: model.library, wide: !isColumn)
                    }
                }

                if !followers.isEmpty {
                    RailBlock(title: "\(countString(user.followersCount ?? 0)) followers",
                              action: "View all", destination: ProfileList.followers(user)) {
                        FollowerFaces(followers: Array(followers.prefix(facesShown)))
                    }
                }
            }
        }
        .task(id: user.id) {
            // Crossing the rail threshold re-runs this with state intact; the data is already here.
            guard loadedID != user.id else { return }
            await load()
            if !Task.isCancelled { loadedID = user.id }
        }
    }

    private func load() async {
        async let liked = try? await model.api.userLikes(id: user.id, limit: 6)
        likes = await liked?.collection ?? []

        guard !isMe else {
            // Through the library rather than the endpoint: it already caches the list, and the
            // follow buttons in the block read their state from the same place — fetched
            // separately, every one of your own follows renders as "Follow".
            model.library.loadFollowingIfNeeded()
            comments = (try? await model.api.userComments(id: user.id))?.collection ?? []
            return
        }

        async let fans = try? await model.api.relatedArtists(id: user.id)
        async let crowd = try? await model.api.userFollowers(id: user.id, limit: 15)
        // The artist is in their own related list often enough to look like a bug.
        related = await fans?.collection.filter { $0.id != user.id } ?? []
        followers = await crowd?.collection ?? []
    }
}

/// A titled block: a quiet uppercase label with an optional control opposite it, the way the site
/// heads every panel in this column.
struct RailBlock<Content: View>: View {
    let title: String
    var action: String?
    var run: (() -> Void)?
    var destination: (any Hashable)?
    @ViewBuilder let content: Content

    init(title: String, action: String? = nil, destination: (any Hashable)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.destination = destination
        self.content = content()
    }

    init(title: String, action: String?, run: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.run = run
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if let action {
                    if let destination {
                        NavButton(value: destination) { actionLabel(action) }
                    } else if let run {
                        Button(action: run) { actionLabel(action) }.buttonStyle(.plain)
                    }
                }
            }
            content
        }
    }

    private func actionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
    }
}

/// A liked track or set, small enough for the column: cover, who made it, and its counts.
private struct LikeMini: View {
    let item: SCLikeItem

    var body: some View {
        NavButton(value: value) {
            HStack(alignment: .top, spacing: 12) {
                cover
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(author).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    counts
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cover: some View {
        switch item.content {
        case .track(let track): Artwork(track, size: .mid)
        case .playlist(let playlist): Artwork(playlist, size: .mid)
        }
    }

    @ViewBuilder
    private var counts: some View {
        switch item.content {
        case .track(let track):
            HStack(spacing: 12) {
                stat("play.fill", track.playbackCount)
                stat("heart.fill", track.likesCount)
                stat("arrow.2.squarepath", track.repostsCount)
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        case .playlist(let playlist):
            Text("\(playlist.trackCount) tracks")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func stat(_ symbol: String, _ value: Int?) -> some View {
        if let value, value > 0 {
            Label(countString(value), systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        }
    }

    private var value: any Hashable {
        switch item.content {
        case .track(let track): track
        case .playlist(let playlist): playlist
        }
    }

    private var title: String {
        switch item.content {
        case .track(let track): track.title
        case .playlist(let playlist): playlist.title
        }
    }

    private var author: String {
        switch item.content {
        case .track(let track): track.user.username
        case .playlist(let playlist): playlist.user?.username ?? ""
        }
    }
}

/// "Fans also like" — an artist per row with the follow control right there, so the whole point of
/// the block (finding someone new to follow) takes one click.
struct ArtistFanList: View {
    let artists: [SCUser]
    let library: LibraryStore
    var wide = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: 24, alignment: .leading)]
    }

    var body: some View {
        if wide {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(artists) { FanRow(artist: $0, library: library) }
            }
        } else {
            VStack(spacing: 4) {
                ForEach(artists) { FanRow(artist: $0, library: library) }
            }
        }
    }
}

private struct FanRow: View {
    let artist: SCUser
    let library: LibraryStore

    private var isFollowing: Bool { library.isFollowing(artist) }

    var body: some View {
        HStack(spacing: 12) {
            NavButton(value: artist) {
                HStack(spacing: 12) {
                    Artwork(artist, size: .mid)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(artist.username)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            if artist.verified == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tint)
                            }
                        }
                        HStack(spacing: 12) {
                            Label(countString(artist.followersCount ?? 0), systemImage: "person.fill")
                            Label(countString(artist.trackCount ?? 0), systemImage: "waveform")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // Neutral, not tinted: three orange buttons stacked down the rail read as the page's
            // main action, and the page's main action is the Follow up in the header.
            Button(isFollowing ? "Following" : "Follow") { library.toggleFollow(artist) }
                .glassButton()
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

/// One of your own comments, the way the site lists them on your page: the track it sits on, then
/// what you said. The whole track comes back with the comment, so the row opens it directly.
private struct CommentMini: View {
    let comment: SCUserComment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("on").foregroundStyle(.tertiary)
                if let track = comment.track {
                    NavButton(value: track) {
                        Text(track.title).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("a track").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let age = comment.ageLabel {
                    Text(age).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-1)
                }
            }
            .font(.system(size: 11.5))

            Text(comment.body)
                .font(.system(size: 12.5))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The overlapping strip of faces the site puts under the follower count. Purely a sample — the
/// count above it is the real number.
struct FollowerFaces: View {
    let followers: [SCUser]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(followers) { follower in
                NavButton(value: follower) {
                    Artwork(follower, size: .thumb)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        .overlay { Circle().strokeBorder(Color(nsColor: .windowBackgroundColor),
                                                          lineWidth: 2) }
                        .help(follower.username)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

#if DEBUG
private func railTrack(_ id: Int, _ title: String, _ artist: String,
                       _ plays: Int, _ likes: Int, _ reposts: Int) -> SCTrack {
    let json = """
    {"id":\(id),"title":"\(title)","duration":214000,"permalink_url":"x","artwork_url":null,\
    "user":{"id":\(id * 7),"username":"\(artist)"},"media":{"transcodings":[]},\
    "track_authorization":"","playback_count":\(plays),"likes_count":\(likes),\
    "reposts_count":\(reposts)}
    """
    return try! JSONDecoder().decode(SCTrack.self, from: Data(json.utf8))
}

private func railUser(_ id: Int, _ name: String, _ followers: Int, _ tracks: Int,
                      _ verified: Bool) -> SCUser {
    let json = """
    {"id":\(id),"username":"\(name)","avatar_url":null,"permalink_url":"x",\
    "followers_count":\(followers),"followings_count":12,"track_count":\(tracks),\
    "likes_count":8,"verified":\(verified),\
    "description":"Nice Bass Bro\\n\\nBooking or any other inquiries damnnicebassbro@gmail.com"}
    """
    return try! JSONDecoder().decode(SCUser.self, from: Data(json.utf8))
}

private func railLike(_ track: SCTrack) -> SCLikeItem {
    let data = try! JSONEncoder().encode(track)
    let json = "{\"created_at\":\"2026-08-01T10:00:00Z\",\"kind\":\"like\",\"track\":"
        + String(decoding: data, as: UTF8.self) + "}"
    return try! JSONDecoder().decode(SCLikeItem.self, from: Data(json.utf8))
}

#Preview("Artist rail") {
    let library = LibraryStore(api: SoundCloudAPI())
    let likes = [railLike(railTrack(1, "MCM (prod. by D8te)", "GSKALE", 2656, 110, 73)),
                 railLike(railTrack(2, "Coachella Star", "Nicebassbro", 99_412, 3557, 141))]
    let fans = [railUser(11, "MAYOT", 4562, 78, false),
                railUser(12, "Finesse Music", 49_100, 1487, false),
                railUser(13, "OG Buda", 213_000, 217, true)]
    let crowd = (20..<8 + 20).map { railUser($0, "Follower \($0)", 5, 0, false) }

    return HStack(alignment: .top, spacing: 32) {
        Text("posts column")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)

        VStack(alignment: .leading, spacing: 26) {
            ArtistInfoRow(user: railUser(1, "Snow Strippers", 72_855, 108, true),
                          model: AppModel(), stacked: true)
            RailBlock(title: "5 likes", action: "View all") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(likes) { LikeMini(item: $0) }
                }
            }
            RailBlock(title: "Fans also like", action: "Refresh") { } content: {
                ArtistFanList(artists: fans, library: library)
            }
            RailBlock(title: "73K followers", action: "View all") {
                FollowerFaces(followers: crowd)
            }
        }
        .frame(width: 320, alignment: .leading)
    }
    .padding(24)
    .frame(width: 1000, height: 860)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}
private func railComment(_ id: Int, _ body: String, on track: SCTrack, at age: String) -> SCUserComment {
    let data = try! JSONEncoder().encode(track)
    let json = "{\"id\":\(id),\"body\":\"\(body)\",\"created_at\":\"\(age)\",\"timestamp\":8219,\"track\":"
        + String(decoding: data, as: UTF8.self) + "}"
    return try! JSONDecoder().decode(SCUserComment.self, from: Data(json.utf8))
}

#Preview("My profile rail") {
    let library = LibraryStore(api: SoundCloudAPI())
    let likes = [railLike(railTrack(1, "MCM (prod. by D8te)", "GSKALE", 2656, 110, 73))]
    let following = [railUser(11, "CODE80", 29_200, 89, false),
                     railUser(12, "дима2хлый", 8, 0, false),
                     railUser(13, "Dimebag Plug", 34, 146, false)]
    let said = [railComment(1, "what a gem 💎", on: railTrack(5, "в падике", "висса", 20_400, 869, 14),
                            at: "2026-02-22T14:58:05Z"),
                railComment(2, "этот дроп меня уничтожил, ставлю на репит",
                            on: railTrack(6, "NEW POLO", "WormGanger", 669_000, 11_600, 143),
                            at: "2026-08-30T10:00:00Z")]

    return HStack(alignment: .top, spacing: 32) {
        Text("posts column")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)

        VStack(alignment: .leading, spacing: 26) {
            ArtistInfoRow(user: railUser(1, "dearonski", 2, 0, false),
                          model: AppModel(), stacked: true)
            RailBlock(title: "1,014 likes", action: "View all") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(likes) { LikeMini(item: $0) }
                }
            }
            RailBlock(title: "4 following", action: "View all") {
                ArtistFanList(artists: following, library: library)
            }
            RailBlock(title: "Latest comments") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(said) { CommentMini(comment: $0) }
                }
            }
        }
        .frame(width: 320, alignment: .leading)
    }
    .padding(24)
    .frame(width: 1000, height: 700)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}
#endif
