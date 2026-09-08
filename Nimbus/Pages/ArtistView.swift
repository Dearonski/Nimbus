import SwiftUI

enum ArtistTab: String, CaseIterable, Identifiable {
    case all = "All"
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

    @Environment(\.metrics) private var metrics

    @State private var tab: ArtistTab = .all
    @State private var all: [SCStreamItem] = []
    @State private var allNextHref: String?
    @State private var spotlight: [SCStreamItem] = []
    @State private var popular: [SCTrack] = []
    @State private var tracks: [SCTrack] = []
    @State private var tracksNextHref: String?
    @State private var albums: [SCPlaylist] = []
    @State private var playlists: [SCPlaylist] = []
    @State private var reposts: [SCStreamItem] = []
    @State private var loadedTabs: Set<ArtistTab> = []
    @State private var isLoading = false
    /// A page is opened from a track, whose nested user carries only id, name and avatar — no
    /// description, no visuals, no counts. The header needs the full profile.
    @State private var profile: SCUser?

    private var artist: SCUser { profile ?? user }

    private var repostTracks: [SCTrack] {
        reposts.compactMap { if case .track(let t) = $0.content { t } else { nil } }
    }

    private func tracks(in items: [SCStreamItem]) -> [SCTrack] {
        items.compactMap { if case .track(let t) = $0.content { t } else { nil } }
    }


    /// The rail only earns its place while the posts beside it still have room for a waveform
    /// card; under this the same blocks stack below them instead.
    private static let railMinimum: CGFloat = 1000
    private static let railWidth: CGFloat = 320

    private var showsRail: Bool { metrics.usable >= Self.railMinimum }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ArtistHeader(user: artist)

                // Tabs left, actions right — six tabs and five controls no longer leave a middle
                // for a centred bar, and it is how the site lays the row out anyway.
                HStack(spacing: 12) {
                    GlassTabBar(tabs: ArtistTab.allCases, title: \.rawValue, selection: $tab)
                    Spacer(minLength: 8)
                    ArtistActions(user: artist, model: model, compact: metrics.usable < 940)
                }
                .controlSize(.large)
                .padding(.horizontal, gutter)
                .padding(.top, 16)
                .padding(.bottom, 16)

                if showsRail {
                    HStack(alignment: .top, spacing: 32) {
                        posts
                        StickyColumn {
                            ArtistRail(user: artist, model: model)
                        }
                        .frame(width: Self.railWidth, alignment: .leading)
                    }
                    .padding(.horizontal, gutter)
                    .padding(.bottom, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ArtistInfoRow(user: artist, model: model)
                        posts
                        ArtistRail(user: artist, model: model, layout: .sections)
                    }
                    .padding(.horizontal, gutter)
                    .padding(.bottom, 8)
                }
            }
        }
        .navigationTitle(artist.username)
        .task(id: user.id) { profile = try? await model.api.user(id: user.id) }
        .task(id: tab) { await load(tab) }
    }

    private var posts: some View {
        LazyVStack(spacing: 2) {
            tabContent
            FeedFooter(isLoading: isLoading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .all:
            if !spotlight.isEmpty {
                SectionHeader(title: "Spotlight", size: 20)
                    .padding(.top, 4)
                LazyVStack(spacing: 20) {
                    ForEach(spotlight) { item in
                        StreamItemView(item: item, model: model, queue: .exactly(tracks(in: spotlight)))
                    }
                }
                .padding(.vertical, 4)
            }
            let allTriggers = all.pagingTriggerIDs
            LazyVStack(spacing: 20) {
                ForEach(all) { item in
                    StreamItemView(item: item, model: model, queue: .exactly(tracks(in: all)))
                        .paginates(allTriggers.contains(item.id)) { await loadMoreAll() }
                }
            }
            .padding(.vertical, 4)
            emptyNote(show: all.isEmpty && spotlight.isEmpty, "Nothing posted yet")
        case .popular:
            trackRows(popular, empty: "No tracks yet")
        case .tracks:
            let triggers = tracks.pagingTriggerIDs
            LazyVStack(spacing: 20) {
                ForEach(tracks) { track in
                    LikeCard(track: track, player: model.player, queue: .exactly(tracks))
                        .paginates(triggers.contains(track.id)) { await loadMoreTracks() }
                }
            }
            .padding(.vertical, 4)
            emptyNote(show: tracks.isEmpty, "No tracks yet")
        case .albums:
            setCards(albums, empty: "No albums yet")
        case .playlists:
            setCards(playlists, empty: "No playlists yet")
        case .reposts:
            LazyVStack(spacing: 20) {
                ForEach(reposts) { item in
                    StreamItemView(item: item, model: model, queue: .exactly(repostTracks))
                }
            }
            .padding(.vertical, 4)
            emptyNote(show: reposts.isEmpty, "No reposts yet")
        }
    }

    @ViewBuilder
    private func trackRows(_ items: [SCTrack], empty: String) -> some View {
        // The card the site lists a track with — cover, waveform, like and repost — rather than a
        // table line. Albums keep their compact row: a set has no waveform to show.
        LazyVStack(spacing: 20) {
            ForEach(items) { track in
                LikeCard(track: track, player: model.player, queue: .exactly(items))
            }
        }
        .padding(.vertical, 4)
        emptyNote(show: items.isEmpty, empty)
    }

    @ViewBuilder
    private func setCards(_ items: [SCPlaylist], empty: String) -> some View {
        LazyVStack(spacing: 20) {
            ForEach(items) { playlist in
                SetCard(playlist: playlist, model: model)
            }
        }
        .padding(.vertical, 4)
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
        case .all:
            // Spotlight is what the artist pinned; the stream is everything they posted, tracks
            // and sets in one timeline. Most profiles pin nothing, so an empty one just vanishes.
            async let pinned = try? await model.api.userSpotlight(id: user.id)
            async let posts = try? await model.api.userStream(id: user.id)
            spotlight = (await pinned)?.collection ?? []
            let page = await posts
            all = page?.collection ?? []
            allNextHref = page?.nextHref
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

    private func loadMoreAll() async {
        guard let href = allNextHref else { return }
        allNextHref = nil
        guard let page = try? await model.api.nextStreamPage(href) else { return }
        all.appendNew(page.collection)
        allNextHref = page.nextHref
    }

    private func loadMoreTracks() async {
        guard let href = tracksNextHref else { return }
        tracksNextHref = nil
        let page = try? await model.api.nextTrackPage(href)
        tracks.appendNew(page?.collection ?? [])
        tracksNextHref = page?.nextHref
    }
}

struct ArtistHeader: View {
    let user: SCUser

    @Environment(LibraryStore.self) private var library: LibraryStore?

    /// Read off soundcloud.com inside its 1208 container. Absolute, not derived from the column:
    /// the banner stretches to whatever width it is given, but the avatar keeps its size and its
    /// distance from the edge at every window size, which is the whole point of these numbers.
    private static let bannerHeight: CGFloat = 254
    private static let plateWidth: CGFloat = 1208
    private static let avatarSize: CGFloat = 198
    private static let inset: CGFloat = 28
    private static let nameGap: CGFloat = 32
    private static let nameSize: CGFloat = 33

    private var isFollowing: Bool { library?.isFollowing(user) ?? false }

    var body: some View {
        ZStack {
            bleed
            plate
        }
        .frame(height: Self.bannerHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .task { library?.loadFollowingIfNeeded() }
    }

    /// The same visual again, blurred across the whole column. The banner itself has to stay 1208
    /// wide — the avatar's inset is measured from its edge, and artists who drew an avatar into
    /// their banner rely on that — so widening it is out, and a bare dark margin reads as a hole.
    private var bleed: some View {
        Artwork(banner: user)
            .frame(height: Self.bannerHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            // `opaque` keeps the blur from sampling transparency at the edges, which greys them.
            .blur(radius: 44, opaque: true)
            .overlay(Color.black.opacity(0.42))
    }

    private var plate: some View {
        Artwork(banner: user)
            .frame(height: Self.bannerHeight)
            .frame(maxWidth: Self.plateWidth)
            .clipped()
            .overlay(alignment: .leading) { identity }
            .shadow(color: .black.opacity(0.35), radius: 18)
    }

    /// Avatar and name ride on the banner rather than sitting under it, which is what makes the
    /// site's header read as one block instead of a picture with a card beneath it.
    private var identity: some View {
        HStack(alignment: .center, spacing: Self.nameGap) {
            Artwork(user, size: .mid)
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(user.username)
                        .font(.system(size: Self.nameSize, weight: .bold))
                        .lineLimit(1)
                    if user.verified == true {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint)
                    }
                }
                .plaque()

                if let city = user.city, !city.isEmpty {
                    Text(city).font(.system(size: 13)).plaque()
                }

                if user.isArtistPro {
                    Label("Artist Pro", systemImage: "star.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.96, green: 0.77, blue: 0.09),
                                    in: RoundedRectangle(cornerRadius: 3))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.inset)
    }
}

/// The site sets header text on opaque slabs rather than dimming the whole banner: a photograph
/// keeps its contrast, and the text stays legible whatever is behind it.
private struct Plaque: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4))
    }
}

private extension View {
    func plaque() -> some View { modifier(Plaque()) }
}

/// Followers / Following / Tracks the way the site stacks them: a quiet label over a loud number.
struct ArtistStats: View {
    let user: SCUser
    /// In the rail the three metrics share the column's full width, each centred in its third;
    /// beside a bio they stay a compact left-aligned group.
    var spread = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: spread ? 0 : 34) {
            stat("Followers", user.followersCount)
            stat("Following", user.followingsCount)
            stat("Tracks", user.trackCount)
        }
    }

    private func stat(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: spread ? .center : .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(countString(value ?? 0)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: spread ? .infinity : nil)
    }
}

/// Who the artist is: counts, bio and the links they listed. Stacked when it sits in the rail,
/// bio-beside-counts when the window is too narrow for a rail and this runs under the banner.
struct ArtistInfoRow: View {
    let user: SCUser
    let model: AppModel
    var stacked = false

    @Environment(\.metrics) private var metrics

    @State private var profiles: [SCWebProfile] = []

    private var bio: String? {
        guard let text = user.description, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 20) {
                    ArtistStats(user: user, spread: true)
                    if let bio { ArtistBio(text: bio) }
                    links
                }
            } else if let bio, metrics.usable >= 700 {
                HStack(alignment: .top, spacing: 34) {
                    // Capped rather than filling the column: a bio set the full width of a wide
                    // window runs past the length a line can comfortably be read at.
                    VStack(alignment: .leading, spacing: 16) {
                        ArtistBio(text: bio)
                        links
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    Spacer(minLength: 12)
                    ArtistStats(user: user)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ArtistStats(user: user)
                    if let bio { ArtistBio(text: bio) }
                    links
                }
            }
        }
        .task(id: user.id) {
            profiles = (try? await model.api.userWebProfiles(id: user.id)) ?? []
        }
    }

    @ViewBuilder
    private var links: some View {
        if !profiles.isEmpty { SocialLinks(profiles: profiles) }
    }
}

/// The description, folded to three lines until asked. Long bios are the norm on SoundCloud and
/// would otherwise push the tracks off the first screen.
struct ArtistBio: View {
    let text: String

    private static let foldedLines = 3

    @State private var expanded = false
    @State private var foldedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    /// SwiftUI will not say whether a Text was clipped, so both shapes are laid out unseen behind
    /// the visible one and their heights compared. Measuring the visible copy instead would break
    /// the moment it expands — it would then match, and the control to fold it back would vanish.
    private var isTruncated: Bool { fullHeight > foldedHeight + 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : Self.foldedLines)
                .fixedSize(horizontal: false, vertical: true)
                .background(alignment: .top) { rulers }

            if isTruncated {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tint)
            }
        }
    }

    private var rulers: some View {
        ZStack(alignment: .top) {
            measured(lines: Self.foldedLines) { foldedHeight = $0 }
            measured(lines: nil) { fullHeight = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func measured(lines: Int?, _ report: @escaping (CGFloat) -> Void) -> some View {
        Text(text)
            .font(.system(size: 13))
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
    }
}

#if DEBUG
private func sampleUser(_ id: Int, _ name: String, _ city: String?, _ verified: Bool,
                        _ bio: String) -> SCUser {
    let json = """
    {"id":\(id),"username":"\(name)","avatar_url":null,"permalink_url":"x",\
    "followers_count":6739122,"followings_count":94,"track_count":299,"likes_count":15,\
    "city":\(city.map { "\"\($0)\"" } ?? "null"),"verified":\(verified),"description":"\(bio)"}
    """
    return try! JSONDecoder().decode(SCUser.self, from: Data(json.utf8))
}

#Preview("Banner widths") {
    let user = sampleUser(1, "Skrillex", "Los Angeles, United States", true, "Bio.")
    return VStack(alignment: .leading, spacing: 24) {
        Text("1208 — the site's own container").font(.caption).foregroundStyle(.secondary)
        ArtistHeader(user: user).frame(width: 1208)
        Text("860 — narrower").font(.caption).foregroundStyle(.secondary)
        ArtistHeader(user: user).frame(width: 860)
        Text("1700 — wider; avatar holds its size and inset").font(.caption).foregroundStyle(.secondary)
        ArtistHeader(user: user).frame(width: 1700)
    }
    .padding(20)
    .frame(width: 1760)
    .tint(.scOrange)
}

#Preview("Artist header") {
    let model = AppModel()
    let longBio = String(repeating: "Twitter / TikTok / Instagram: @Skrillex. Kora EP "
        + "out now, plus every tour date, label credit and thank-you an artist can fit "
        + "into a profile. ", count: 4)
    return ScrollView {
        VStack(spacing: 0) {
            ForEach([sampleUser(1, "Skrillex", "Los Angeles, United States", true, longBio),
                     sampleUser(3, "Kuru", "Berlin", false,
                                "Two lines only, so the fold control has nothing to do.")],
                    id: \.id) { user in
                VStack(spacing: 0) {
                    ArtistHeader(user: user)

                    HStack(spacing: 12) {
                        GlassTabBar(tabs: ArtistTab.allCases, title: \.rawValue,
                                    selection: .constant(.popular))
                        Spacer(minLength: 8)
                        ArtistActions(user: user, model: model)
                    }
                    .controlSize(.large)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)

                    ArtistInfoRow(user: user, model: model)
                        .padding(.horizontal, 12)
                }
                .padding(.bottom, 28)
            }
        }
    }
    .environment(model.library)
    .frame(width: 1180, height: 900)
    .tint(.scOrange)
}
#endif
