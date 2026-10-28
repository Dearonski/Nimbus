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
    @Environment(\.onTitleCollapse) private var onTitleCollapse

    @State private var page: ArtistPageModel?
    @State private var tab: ArtistTab = .all
    @State private var confirmingHeaderRemoval = false

    /// The rail only earns its place while the posts beside it still have room for a waveform
    /// card; under this the same blocks stack below them instead.
    private static let railMinimum: CGFloat = 1000
    private static let railWidth: CGFloat = 320

    private var showsRail: Bool {
        room?.fitsRail(Self.railWidth, spacing: 32, minimum: Self.railMinimum) ?? (metrics.usable >= Self.railMinimum)
    }
    private var compactActions: Bool { (room?.settledUsable ?? metrics.usable) < 940 }

    var body: some View {
        ZStack {
            if let page { list(page) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Remove your header image?", isPresented: $confirmingHeaderRemoval) {
            Button("Remove", role: .destructive, action: removeHeaderImage)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your profile will show a plain header until you upload a new one.")
        }
        .task(id: user.id) {
            // A kept page runs this again every time it is shown; a new model threw away what it had.
            if page?.id != user.id {
                page = model.pages.model(for: .artist(user.id, isMe: isMe)) {
                    ArtistPageModel(user: user, isMe: isMe, api: model.api)
                }
            }
            guard let page else { return }
            async let profile: Void = page.loadProfile()
            await page.loadRail()
            await profile
        }
        .task(id: TabLoad(page: page?.id, tab: tab)) { await page?.load(tab) }
    }

    /// Keyed on the model too: a first pass that ran before it existed would never be asked again.
    private struct TabLoad: Equatable {
        let page: Int?
        let tab: ArtistTab
    }

    private func list(_ page: ArtistPageModel) -> some View {
        let artist = page.profile ?? user
        return CardCollection(items: entries(page),
                              rows: .measured(by: \.heightKey, token: metrics.listArtwork),
                              insets: NSEdgeInsets(top: 0, left: gutter, bottom: 8, right: gutter),
                              spacing: 20,
                              bottomReserve: PlayerPill.reservedHeight,
                              paging: paging(page),
                              chrome: CardCollectionChrome(
                                  header: AnyView(header(page, artist: artist)),
                                  side: CardCollectionSide(
                                      width: Self.railWidth, spacing: 32, isBeside: showsRail, pins: true,
                                      content: AnyView(ArtistRail(user: artist, page: page, model: model,
                                                                  layout: showsRail ? .column : .sections, isMe: isMe) {
                                          tab = .tracks
                                      })),
                                  onTitleCollapse: { onTitleCollapse($0) }),
                              onPrefetch: Entry.warm) { entry in
            card(entry, page: page)
        }
        .ignoresSafeArea()
    }

    private func reloadProfile() {
        Task { await page?.reloadProfile() }
        if isMe { model.library.reloadMe() }
    }

    private func pickHeaderImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url, let page else { return }
        Task {
            do {
                try await page.uploadHeader(file)
                model.library.reloadMe()
            } catch {
                model.player.report("Couldn't upload the header image")
            }
        }
    }

    private func removeHeaderImage() {
        guard let page else { return }
        Task {
            do {
                try await page.removeHeader()
                model.library.reloadMe()
            } catch {
                model.player.report("Couldn't remove the header image")
            }
        }
    }

    /// The banner, then tabs left and actions right — six tabs and five controls no longer leave a
    /// middle for a centred bar, and it is how the site lays the row out anyway.
    private func header(_ page: ArtistPageModel, artist: SCUser) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtistHeader(user: artist, activity: page.headerActivity,
                         onUpload: isMe ? { pickHeaderImage() } : nil,
                         onRemove: isMe ? { confirmingHeaderRemoval = true } : nil)

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
            .padding(.vertical, 16)

            if !showsRail {
                ArtistInfoRow(user: artist, links: page.links) { tab = .tracks }
                    .padding(.horizontal, gutter)
                    .padding(.bottom, 26)
            }
        }
    }

    private func paging(_ page: ArtistPageModel) -> ListPaging? {
        if page.loadingTabs.contains(tab) { return ListPaging(isLoading: true, padding: 20) }
        switch tab {
        case .all: return ListPaging(page.allPages, padding: 20)
        case .tracks: return ListPaging(page.trackPages, padding: 20)
        default: return nil
        }
    }

    /// One flat list a tab: the cards the site lists a track with — cover, waveform, like and
    /// repost — rather than table lines, and a set's compact card where there is no waveform to show.
    fileprivate enum Entry: Identifiable {
        case heading(String)
        case post(SCStreamItem, pinned: Bool)
        case track(SCTrack)
        case set(SCPlaylist)
        case note(String)
        case failure(String)

        // A pinned post is usually in the stream under it as well.
        var id: AnyHashable {
            switch self {
            case .heading(let title): ["heading", title] as [AnyHashable]
            case .post(let item, let pinned): [pinned ? "pinned" : "post", item.id] as [AnyHashable]
            case .track(let track): ["track", track.id] as [AnyHashable]
            case .set(let playlist): ["set", playlist.id] as [AnyHashable]
            case .note: "note"
            case .failure: "failure"
            }
        }

        var heightKey: AnyHashable {
            switch self {
            case .heading: "heading"
            case .post(let item, _): ["post", StreamItemView.heightVariant(of: item)] as [AnyHashable]
            case .track(let track): ["track", LikeCard.heightVariant(of: track)] as [AnyHashable]
            case .set(let playlist): SetCard.heightVariant(of: playlist)
            case .note: "note"
            case .failure(let message): ["failure", message] as [AnyHashable]
            }
        }

        static func warm(_ entries: [Entry]) {
            StreamItemView.warm(entries.compactMap { if case .post(let item, _) = $0 { item } else { nil } })
            LikeCard.warm(entries.compactMap { if case .track(let track) = $0 { track } else { nil } })
        }
    }

    private func entries(_ page: ArtistPageModel) -> [Entry] {
        let rows: [Entry]
        let empty: String
        switch tab {
        case .all:
            let pinned = page.spotlight.isEmpty ? [] : [.heading("Spotlight")] + page.spotlight.map { Entry.post($0, pinned: true) }
            rows = pinned + page.allPages.items.map { .post($0, pinned: false) }
            empty = "Nothing posted yet"
        case .popular:
            rows = page.popular.map(Entry.track)
            empty = "No tracks yet"
        case .tracks:
            rows = page.trackPages.items.map(Entry.track)
            empty = "No tracks yet"
        case .albums:
            rows = page.albums.map(Entry.set)
            empty = "No albums yet"
        case .playlists:
            rows = page.playlists.map(Entry.set)
            empty = "No playlists yet"
        case .reposts:
            rows = page.reposts.map { .post($0, pinned: false) }
            empty = "No reposts yet"
        }
        let phase = ListPhase(isEmpty: rows.isEmpty, isLoading: page.loadingTabs.contains(tab),
                              error: page.tabErrors[tab], wasAsked: page.loadedTabs.contains(tab) || page.tabErrors[tab] != nil)
        switch phase {
        case .failed(let error): return [.failure(error)]
        case .empty: return [.note(empty)]
        case .loading, .rows: return rows
        }
    }

    private func tracks(in items: [SCStreamItem]) -> [SCTrack] {
        items.compactMap { if case .track(let t) = $0.content { t } else { nil } }
    }

    @ViewBuilder
    private func card(_ entry: Entry, page: ArtistPageModel) -> some View {
        switch entry {
        case .heading(let title):
            SectionHeader(title: title, size: 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The list spaces every row alike; a heading sits closer to what it names.
                .padding(.bottom, -12)
        case .post(let item, let pinned):
            let source = pinned ? page.spotlight : tab == .reposts ? page.reposts : page.allPages.items
            StreamItemView(item: item, model: model, queue: .exactly(tracks(in: source)))
        case .track(let track):
            LikeCard(track: track, player: model.player,
                     queue: .exactly(tab == .popular ? page.popular : page.trackPages.items))
        case .set(let playlist):
            // A recycled cell would carry one set's spinner onto the next.
            SetCard(playlist: playlist, model: model).id(playlist.id)
        case .note(let text):
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
        case .failure(let message):
            LoadFailure(message: message) { Task { await page.load(tab) } }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
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
                VerifiedName(user, spacing: 6 * scale)
                    .font(.system(size: Self.nameSize * scale, weight: .bold))
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
    let links: [SCWebProfile]
    var stacked = false
    var onShowTracks: (() -> Void)?

    @Environment(\.metrics) private var metrics
    @Environment(PageRoom.self) private var room: PageRoom?

    private var bioBeside: Bool { (room?.settledUsable ?? metrics.usable) >= 700 }

    private var bio: String? {
        guard let text = user.description, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 20) {
                    StatTiles.profile(user, onTracks: onShowTracks)
                    if let bio { ArtistBio(text: bio) }
                    linkRow
                }
            } else if let bio, bioBeside {
                HStack(alignment: .top, spacing: 34) {
                    // Capped rather than filling the column: a bio set the full width of a wide
                    // window runs past the length a line can comfortably be read at.
                    VStack(alignment: .leading, spacing: 16) {
                        ArtistBio(text: bio)
                        linkRow
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    Spacer(minLength: 12)
                    // The rail's own width, so the tiles keep the size they have beside the posts.
                    StatTiles.profile(user, onTracks: onShowTracks)
                        .frame(width: 320)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    StatTiles.profile(user, onTracks: onShowTracks)
                        .frame(maxWidth: 420)
                    if let bio { ArtistBio(text: bio) }
                    linkRow
                }
            }
        }
        .animation(.snappy, value: bioBeside)
    }

    @ViewBuilder
    private var linkRow: some View {
        if !links.isEmpty { SocialLinks(profiles: links) }
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

                    ArtistInfoRow(user: user, links: [])
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
