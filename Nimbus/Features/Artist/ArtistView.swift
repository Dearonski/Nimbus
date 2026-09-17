import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    /// The signed-in user's own page. Same shape — header, tabs, posts, rail — with the controls
    /// and the last two rail blocks the site swaps out for you.
    var isMe = false

    @Environment(\.metrics) private var metrics
    @Environment(PageRoom.self) private var room: PageRoom?

    @State private var tab: ArtistTab = .all
    @State private var allPages: Pager<SCStreamItem>?
    @State private var spotlight: [SCStreamItem] = []
    @State private var popular: [SCTrack] = []
    @State private var trackPages: Pager<SCTrack>?
    @State private var albums: [SCPlaylist] = []
    @State private var playlists: [SCPlaylist] = []
    @State private var reposts: [SCStreamItem] = []
    @State private var loadedTabs: Set<ArtistTab> = []
    @State private var tabErrors: [ArtistTab: String] = [:]
    @State private var isLoading = false
    /// A page is opened from a track, whose nested user carries only id, name and avatar — no
    /// description, no visuals, no counts. The header needs the full profile.
    @State private var profile: SCUser?
    /// What is happening to the header right now — "Uploading…", "Removing…" — or nil when idle.
    @State private var headerActivity: String?
    @State private var confirmingHeaderRemoval = false

    private var artist: SCUser { profile ?? user }

    private func tracks(in items: [SCStreamItem]) -> [SCTrack] {
        items.compactMap { if case .track(let t) = $0.content { t } else { nil } }
    }

    /// The rail only earns its place while the posts beside it still have room for a waveform
    /// card; under this the same blocks stack below them instead.
    private static let railMinimum: CGFloat = 1000
    private static let railWidth: CGFloat = 320

    private var showsRail: Bool {
        room?.fitsRail(Self.railWidth, spacing: 32, minimum: Self.railMinimum) ?? (metrics.usable >= Self.railMinimum)
    }
    private var compactActions: Bool { (room?.settledUsable ?? metrics.usable) < 940 }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ArtistHeader(user: artist, activity: headerActivity,
                             onUpload: isMe ? { pickHeaderImage() } : nil,
                             onRemove: isMe ? { confirmingHeaderRemoval = true } : nil)

                // Tabs left, actions right — six tabs and five controls no longer leave a middle
                // for a centred bar, and it is how the site lays the row out anyway.
                HStack(spacing: 12) {
                    GlassTabBar(tabs: ArtistTab.allCases, title: \.rawValue, selection: $tab)
                    Spacer(minLength: 8)
                    if isMe {
                        MyProfileActions(user: artist, model: model, compact: compactActions,
                                         onProfileChanged: reloadProfile)
                    } else {
                        ArtistActions(user: artist, model: model, compact: compactActions)
                    }
                }
                .animation(.snappy, value: compactActions)
                .controlSize(.large)
                .padding(.horizontal, gutter)
                .padding(.top, 16)
                .padding(.bottom, 16)

                // AnyLayout, not if/else: the posts and the rail keep their identity, so crossing the
                // threshold moves them into place instead of swapping one page for another.
                let layout = showsRail
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
                layout {
                    if !showsRail { ArtistInfoRow(user: artist, model: model) }
                    posts
                    StickyColumn(pins: showsRail) {
                        ArtistRail(user: artist, model: model, layout: showsRail ? .column : .sections, isMe: isMe)
                    }
                    .frame(width: showsRail ? Self.railWidth : nil, alignment: .leading)
                }
                .padding(.horizontal, gutter)
                .padding(.bottom, 8)
                .animation(.snappy, value: showsRail)
            }
        }
        .navigationTitle(artist.username)
        .confirmationDialog("Remove your header image?", isPresented: $confirmingHeaderRemoval) {
            Button("Remove", role: .destructive, action: removeHeaderImage)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your profile will show a plain header until you upload a new one.")
        }
        .task(id: user.id) { profile = try? await model.api.user(id: user.id) }
        .task(id: tab) { await load(tab) }
    }

    /// Through `/me` on your own page: a public profile fetched right after an edit can still come
    /// back as it was a moment ago, and a save that shows the old values reads as one that failed.
    private func reloadProfile() {
        Task {
            profile = isMe ? try? await model.api.meUser() : try? await model.api.user(id: user.id)
        }
        if isMe { model.library.reloadMe() }
    }

    private func pickHeaderImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }

        headerActivity = "Uploading…"
        Task {
            defer { headerActivity = nil }
            do {
                try await model.api.uploadProfileHeader(file)
                reloadProfile()
            } catch {
                model.player.report("Couldn't upload the header image")
            }
        }
    }

    private func removeHeaderImage() {
        headerActivity = "Removing…"
        Task {
            defer { headerActivity = nil }
            do {
                try await model.api.removeProfileHeader()
                reloadProfile()
            } catch {
                model.player.report("Couldn't remove the header image")
            }
        }
    }

    private var posts: some View {
        LazyVStack(spacing: 2) {
            if let error = tabErrors[tab], !isLoading {
                LoadFailure(message: error) { Task { await load(tab) } }
                    .padding(.vertical, 24)
            } else {
                tabContent
            }
            if isLoading {
                FeedFooter(isLoading: true)
            } else if tab == .all, let allPages {
                FeedFooter(pager: allPages)
            } else if tab == .tracks, let trackPages {
                FeedFooter(pager: trackPages)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .all:
            let all = allPages?.items ?? []
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
                        .paginates(allTriggers.contains(item.id)) { await allPages?.loadMore() }
                }
            }
            .padding(.vertical, 4)
            emptyNote(show: all.isEmpty && spotlight.isEmpty, "Nothing posted yet")
        case .popular:
            trackRows(popular, empty: "No tracks yet")
        case .tracks:
            let uploads = trackPages?.items ?? []
            let triggers = uploads.pagingTriggerIDs
            LazyVStack(spacing: 20) {
                ForEach(uploads) { track in
                    LikeCard(track: track, player: model.player, queue: .exactly(uploads))
                        .paginates(triggers.contains(track.id)) { await trackPages?.loadMore() }
                }
            }
            .padding(.vertical, 4)
            emptyNote(show: uploads.isEmpty, "No tracks yet")
        case .albums:
            setCards(albums, empty: "No albums yet")
        case .playlists:
            setCards(playlists, empty: "No playlists yet")
        case .reposts:
            LazyVStack(spacing: 20) {
                ForEach(reposts) { item in
                    StreamItemView(item: item, model: model, queue: .exactly(tracks(in: reposts)))
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
        defer { isLoading = false }
        tabErrors[tab] = nil
        let api = model.api, id = user.id
        var failure: String?
        do {
            switch tab {
            case .all:
                // Spotlight is what the artist pinned; the stream is everything they posted, tracks
                // and sets in one timeline. Most profiles pin nothing, so an empty one just vanishes.
                async let pinned = try? await api.userSpotlight(id: id)
                let pages = allPages ?? Pager(first: { try await api.userStream(id: id).page },
                                              next: { try await api.nextStreamPage($0).page })
                allPages = pages
                await pages.loadMore()
                spotlight = (await pinned)?.collection ?? []
                failure = pages.firstPageError
            case .popular:
                popular = try await api.userTopTracks(id: id).collection
            case .tracks:
                let pages = trackPages ?? Pager(first: { try await api.userTracks(id: id).page },
                                                next: { try await api.nextTrackPage($0).page })
                trackPages = pages
                await pages.loadMore()
                failure = pages.firstPageError
            case .albums:
                albums = try await api.userAlbums(id: id)
            case .playlists:
                playlists = try await api.userPlaylists(id: id)
            case .reposts:
                reposts = try await api.userReposts(id: id).collection
            }
        } catch {
            failure = "\(error)"
        }
        // Switching tabs cancels the load: neither a failure nor loaded, so coming back asks again.
        guard !Task.isCancelled else { return }
        if let failure {
            tabErrors[tab] = failure
        } else {
            loadedTabs.insert(tab)
        }
    }
}

struct ArtistHeader: View {
    let user: SCUser
    var activity: String?
    /// Set on your own page only: the banner carries the controls that replace and remove it, top
    /// right, the way the site puts them.
    var onUpload: (() -> Void)?
    var onRemove: (() -> Void)?

    @Environment(LibraryStore.self) private var library: LibraryStore?

    /// Read off soundcloud.com inside its 1208 container. Narrower than that, the whole plate scales
    /// down as one picture — banner, avatar, inset and name together — so an avatar an artist drew
    /// into their banner stays where they drew it, and the name never outgrows the banner under it.
    private static let bannerHeight: CGFloat = 254
    private static let plateWidth: CGFloat = 1208
    private static let avatarSize: CGFloat = 198
    private static let inset: CGFloat = 28
    private static let nameGap: CGFloat = 32
    private static let nameSize: CGFloat = 33

    @State private var width = plateWidth

    private var scale: CGFloat { min(1, width / Self.plateWidth) }

    var body: some View {
        ZStack {
            bleed
            plate
        }
        .frame(height: Self.bannerHeight * scale)
        .frame(maxWidth: .infinity)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .task { library?.loadFollowingIfNeeded() }
    }

    /// The same visual again, blurred across the whole column. The banner itself has to stay 1208
    /// wide — the avatar's inset is measured from its edge, and artists who drew an avatar into
    /// their banner rely on that — so widening it is out, and a bare dark margin reads as a hole.
    private var bleed: some View {
        Color.clear
            .frame(height: Self.bannerHeight * scale)
            .frame(maxWidth: .infinity)
            .overlay { Artwork(banner: user) }
            .clipped()
            // `opaque` keeps the blur from sampling transparency at the edges, which greys them.
            .blur(radius: 44, opaque: true)
            .overlay(Color.black.opacity(0.42))
    }

    private var plate: some View {
        // The picture rides in an overlay: laid out directly, a filled banner reported its own width —
        // 254 times its aspect, 1213 — and held the whole page at least that wide, so it never scaled.
        Color.clear
            .frame(height: Self.bannerHeight * scale)
            .frame(maxWidth: Self.plateWidth)
            .overlay { Artwork(banner: user) }
            .clipped()
            .overlay(alignment: .leading) { identity }
            .overlay(alignment: .topTrailing) {
                if let onUpload { headerControl(upload: onUpload) }
            }
            .shadow(color: .black.opacity(0.35), radius: 18)
    }

    /// One plaque either way: a plain upload while there is nothing to remove, a menu once there is.
    @ViewBuilder
    private func headerControl(upload: @escaping () -> Void) -> some View {
        Group {
            if let activity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(activity)
                }
                .font(.system(size: 12, weight: .semibold))
                .plaque()
            } else if user.bannerURL != nil, let onRemove {
                Menu {
                    Button("Replace Image…", systemImage: "photo", action: upload)
                    Button("Remove Image", systemImage: "trash", role: .destructive, action: onRemove)
                } label: {
                    HStack(spacing: 5) {
                        Text("Header image")
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .plaque()
                }
                // `.button` with a plain style draws the label as given; `.borderlessButton` threw
                // the plaque away and set the words in tinted system text with the chevron in front.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button(action: upload) {
                    Text("Upload header image")
                        .font(.system(size: 12, weight: .semibold))
                        .plaque()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    /// Avatar and name ride on the banner rather than sitting under it, which is what makes the
    /// site's header read as one block instead of a picture with a card beneath it.
    private var identity: some View {
        HStack(alignment: .center, spacing: Self.nameGap * scale) {
            Artwork(user, size: .mid)
                .frame(width: Self.avatarSize * scale, height: Self.avatarSize * scale)
                .clipShape(Circle())
                .opensArtwork(user.avatarURL, preview: .mid, title: user.username, circle: true)

            VStack(alignment: .leading, spacing: 6 * scale) {
                HStack(spacing: 6 * scale) {
                    Text(user.username)
                        .font(.system(size: Self.nameSize * scale, weight: .bold))
                        .lineLimit(1)
                    if user.verified == true {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint)
                    }
                }
                .plaque(scale)

                if let city = user.city, !city.isEmpty {
                    // The small lines keep a floor: scaled with the rest they stop being readable first.
                    Text(city).font(.system(size: max(13 * scale, 9))).plaque(scale)
                }

                if user.isArtistPro {
                    Label("Artist Pro", systemImage: "star.circle.fill")
                        .font(.system(size: max(10 * scale, 8), weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6 * scale)
                        .padding(.vertical, 3 * scale)
                        .background(Color(red: 0.96, green: 0.77, blue: 0.09),
                                    in: RoundedRectangle(cornerRadius: 3 * scale))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.inset * scale)
    }
}

/// The site sets header text on opaque slabs rather than dimming the whole banner: a photograph
/// keeps its contrast, and the text stays legible whatever is behind it.
private struct Plaque: ViewModifier {
    var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 3 * scale)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4 * scale))
    }
}

private extension View {
    func plaque(_ scale: CGFloat = 1) -> some View { modifier(Plaque(scale: scale)) }
}

/// Who the artist is: counts, bio and the links they listed. Stacked when it sits in the rail,
/// bio-beside-counts when the window is too narrow for a rail and this runs under the banner.
struct ArtistInfoRow: View {
    let user: SCUser
    let model: AppModel
    var stacked = false

    @Environment(\.metrics) private var metrics
    @Environment(PageRoom.self) private var room: PageRoom?

    @State private var profiles: [SCWebProfile] = []

    // The row is rebuilt whenever the rail crosses its threshold; the links it lists don't change that often.
    private static var profileCache: [Int: [SCWebProfile]] = [:]

    private var bioBeside: Bool { (room?.settledUsable ?? metrics.usable) >= 700 }

    private var bio: String? {
        guard let text = user.description, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 20) {
                    StatTiles.profile(user)
                    if let bio { ArtistBio(text: bio) }
                    links
                }
            } else if let bio, bioBeside {
                HStack(alignment: .top, spacing: 34) {
                    // Capped rather than filling the column: a bio set the full width of a wide
                    // window runs past the length a line can comfortably be read at.
                    VStack(alignment: .leading, spacing: 16) {
                        ArtistBio(text: bio)
                        links
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    Spacer(minLength: 12)
                    // The rail's own width, so the tiles keep the size they have beside the posts.
                    StatTiles.profile(user)
                        .frame(width: 320)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    StatTiles.profile(user)
                        .frame(maxWidth: 420)
                    if let bio { ArtistBio(text: bio) }
                    links
                }
            }
        }
        .animation(.snappy, value: bioBeside)
        .task(id: user.id) {
            if let cached = Self.profileCache[user.id] {
                profiles = cached
                return
            }
            profiles = []
            guard let fetched = try? await model.api.userWebProfiles(id: user.id), !Task.isCancelled else { return }
            Self.profileCache[user.id] = fetched
            profiles = fetched
        }
    }

    @ViewBuilder
    private var links: some View {
        if !profiles.isEmpty { SocialLinks(profiles: profiles) }
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

/// The three states of the control your own header carries: nothing to remove yet, a banner to
/// replace or remove, and a change in flight.
#Preview("Header controls") {
    let bare = sampleUser(7, "dearonski", "", false, "")
    // A banner URL that won't load still counts as a banner — the control reads the URL, not pixels.
    let withBanner = try! JSONDecoder().decode(SCUser.self, from: Data("""
    {"id":8,"username":"dearonski","avatar_url":null,"permalink_url":"x",
     "visuals":{"visuals":[{"visual_url":"https://example.invalid/banner.jpg"}]}}
    """.utf8))
    return VStack(spacing: 16) {
        ArtistHeader(user: bare, onUpload: {}, onRemove: {})
        ArtistHeader(user: withBanner, onUpload: {}, onRemove: {})
        ArtistHeader(user: withBanner, activity: "Removing…", onUpload: {}, onRemove: {})
    }
    .frame(width: 1100)
    .background(Color(nsColor: .windowBackgroundColor))
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
