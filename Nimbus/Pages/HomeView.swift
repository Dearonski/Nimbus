import SwiftUI

/// Home answers "what should I play?", not "what is popular". Its spine is SoundCloud's own
/// discover feed (`/mixed-selections`): a featured mix, your re-entry points, then the curated
/// shelves. The chart is one section among many, not the page.
///
/// Shelves rotate archetype (square sets → people circles → wide mixes) so the page never reads
/// as the same card repeated, which is the failure mode of both our old Home and nuage's.
struct HomeView: View {
    let model: AppModel
    @State private var genre = SCGenre.all

    private var selections: [SCMixedSelection] { model.library.selections }
    private var featured: SCPlaylist? { selections.first?.playlists.first }
    private var recentTracks: [SCTrack] { model.library.history.tracks }

    /// The people shelf SoundCloud sends ("Artists to watch out for"); when the feed has none,
    /// fall back to the artists behind the chart — free, no extra request.
    private var artists: [SCUser] {
        // The people shelf can repeat a user; a duplicate id makes ForEach render undefined rows.
        let shelf = selections.first(where: \.isPeopleShelf)?.users ?? model.library.chartArtists
        var seen = Set<Int>()
        return shelf.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                FeaturedMix(playlist: featured, eyebrow: selections.first?.title, model: model)

                if !recentTracks.isEmpty {
                    RecentGrid(tracks: Array(recentTracks.prefix(6)), player: model.player)
                }

                ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
                    SelectionShelf(shelf: shelf, style: index.isMultiple(of: 2) ? .square : .wide,
                                   model: model)

                    if index == 0, !artists.isEmpty {
                        ArtistShelf(artists: Array(artists.prefix(12)))
                    }
                    if index == 1 { chart }
                }

                if shelves.count < 2 { chart }
            }
            .padding(.vertical, 20)
        }
        .navigationTitle("Home")
        .task {
            model.library.loadSelectionsIfNeeded()
            model.library.history.loadInitialIfNeeded()
            model.library.loadTrendingIfNeeded()
        }
        .onChange(of: genre) { _, newGenre in
            model.library.reloadTrending(genre: newGenre.slug)
        }
    }

    private var chart: some View {
        ChartSection(tracks: model.library.trending, player: model.player,
                     genre: $genre, isLoading: model.library.isLoadingTrending)
    }

    /// Sections we render ourselves, in richer form, than the shelf the feed would give us.
    private static let ownedShelves: Set<String> = ["recently played", "charts", "history"]

    /// The featured mix is lifted out of the first shelf so it isn't shown twice.
    private var shelves: [ShelfData] {
        var isFirst = true
        return selections.compactMap { selection in
            guard !selection.isPeopleShelf,
                  !Self.ownedShelves.contains(selection.title.lowercased())
            else { return nil }
            var playlists = selection.playlists
            if isFirst {
                isFirst = false
                playlists = Array(playlists.dropFirst())
            }
            guard !playlists.isEmpty else { return nil }
            return ShelfData(id: selection.id, title: selection.title,
                             subtitle: selection.description, playlists: playlists)
        }
    }
}

struct ShelfData: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let playlists: [SCPlaylist]
}

// MARK: - 1. Featured mix — one confident answer to "what should I play?"

struct FeaturedMix: View {
    let playlist: SCPlaylist?
    let eyebrow: String?
    let model: AppModel

    @State private var isStarting = false

    var body: some View {
        Group {
            if let playlist {
                card(playlist)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.quaternary)
                    .frame(height: 200)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, gutter)
    }

    private func card(_ playlist: SCPlaylist) -> some View {
        HStack(alignment: .top, spacing: 22) {
            NavigationLink(value: playlist) {
                Artwork(url: playlist.artworkURL.scArtwork())
                    .frame(width: 164, height: 164)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text((eyebrow ?? "Featured").uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.tint)

                Text(playlist.title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)

                if let description = playlist.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let author = playlist.user?.username {
                    Text(author).font(.system(size: 14)).foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                HStack(spacing: 12) {
                    Button { start(playlist, shuffled: false) } label: {
                        Label("Play", systemImage: "play.fill").frame(minWidth: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button { start(playlist, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if isStarting { ProgressView().controlSize(.small) }

                    Text("\(playlist.trackCount) tracks")
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(height: 204)
        .background {
            Artwork(url: playlist.artworkURL.scArtwork())
                .blur(radius: 52, opaque: true)
                .overlay(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.07))
        }
    }

    private func start(_ playlist: SCPlaylist, shuffled: Bool) {
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            await model.play(playlist, shuffled: shuffled)
        }
    }
}

// MARK: - 2. Recently played — the only 2-D grid, the density hit

/// Deliberately not "pick up where you left off": no per-track playback offset is stored
/// anywhere, so a tap restarts the track. The label names what actually happens.
struct RecentGrid: View {
    let tracks: [SCTrack]
    let player: PlayerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recently played", size: 18)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                ForEach(tracks) { track in
                    RecentPill(track: track, player: player, context: tracks)
                }
            }
            .padding(.horizontal, gutter)
        }
    }
}

struct RecentPill: View {
    let track: SCTrack
    let player: PlayerEngine
    let context: [SCTrack]

    @State private var hovering = false
    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                Artwork(url: track.artworkURL.scArtwork("t300x300"))
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    Text(track.artistLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                    .opacity(hovering ? 1 : 0)
                    .padding(.trailing, 12)
            }
            .padding(6)
            .frame(height: 60)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.04))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .trackContextMenu(track, player: player)
    }

    private func play() {
        if isCurrent {
            player.togglePlayPause()
        } else {
            Task { await player.play(track, in: context) }
        }
    }
}

// MARK: - 3. Selection shelves — SoundCloud's own discover feed

enum ShelfStyle {
    case square, wide
}

struct SelectionShelf: View {
    let shelf: ShelfData
    let style: ShelfStyle
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: shelf.title, subtitle: shelf.subtitle, size: 20)

            Shelf {
                ForEach(shelf.playlists) { playlist in
                    switch style {
                    case .square: SquareSetCard(playlist: playlist, model: model)
                    case .wide: WideSetCard(playlist: playlist, model: model)
                    }
                }
            }
        }
    }
}

/// Resolving a playlist's tracks takes a request, so the button reports that it is working
/// instead of looking dead for a second.
private struct PlayFAB: View {
    let size: CGFloat
    let isStarting: Bool

    var body: some View {
        Circle()
            .fill(.tint)
            .frame(width: size, height: size)
            .overlay {
                if isStarting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: size * 0.38))
                        .foregroundStyle(.white)
                }
            }
    }
}

/// Artwork plays, the caption opens the page — the split `TrackCard` already uses. Wrapping the
/// whole card in a NavigationLink swallowed the play button's click, so the button was a lie.
struct SquareSetCard: View {
    let playlist: SCPlaylist
    let model: AppModel

    @State private var hovering = false
    @State private var isStarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: play) {
                ZStack {
                    Artwork(url: playlist.artworkURL.scArtwork())
                        .frame(width: 176, height: 176)
                    if hovering || isStarting {
                        Color.black.opacity(0.3)
                        PlayFAB(size: 40, isStarting: isStarting)
                    }
                }
                .frame(width: 176, height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink(value: playlist) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(playlist.byline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 176, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 176, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private func play() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            await model.play(playlist)
        }
    }
}

/// The title overlays the artwork here, so the card plays and only the title text navigates.
struct WideSetCard: View {
    let playlist: SCPlaylist
    let model: AppModel

    @State private var hovering = false
    @State private var isStarting = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Button(action: play) {
                ZStack {
                    Artwork(url: playlist.artworkURL.scArtwork())
                        .frame(width: 268, height: 150)

                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0), location: 0.25),
                            .init(color: .black.opacity(0.55), location: 0.6),
                            .init(color: .black.opacity(0.9), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom)
                }
                .frame(width: 268, height: 150)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                NavigationLink(value: playlist) {
                    Text(playlist.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                Text("\(playlist.trackCount) tracks")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(12)

            if hovering || isStarting {
                PlayFAB(size: 36, isStarting: isStarting)
                    .padding(12)
                    .frame(width: 268, height: 150, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 268, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
    }

    private func play() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            await model.play(playlist)
        }
    }
}

// MARK: - 4. Artists — the only round shape on the page

struct ArtistShelf: View {
    let artists: [SCUser]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Artists on the rise", size: 20)
            Shelf(spacing: 20) {
                ForEach(artists) { ArtistCircle(artist: $0) }
            }
        }
    }
}

// MARK: - 5. The chart — one section among many, not the page

struct ChartSection: View {
    let tracks: [SCTrack]
    let player: PlayerEngine
    @Binding var genre: SCGenre
    var isLoading = false

    @State private var showAll = false

    private var visible: [SCTrack] { showAll ? tracks : Array(tracks.prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Charts", subtitle: "What's trending right now", size: 20)

            GenreChipsRow(selection: $genre)

            if tracks.isEmpty && isLoading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .frame(height: 100)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, track in
                        ChartRow(rank: index + 1, track: track, player: player, context: tracks)
                    }
                }
                .padding(.horizontal, gutter - 10)

                if tracks.count > 5 {
                    Button(showAll ? "Show less" : "Show all \(tracks.count)") {
                        withAnimation(.snappy) { showAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, gutter)
                }
            }
        }
    }
}

/// The real filter for the chart below it.
struct GenreChipsRow: View {
    @Binding var selection: SCGenre

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([SCGenre.all] + SCGenre.browse) { genre in
                    let isSelected = genre == selection
                    Button { selection = genre } label: {
                        Text(genre.name)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                in: Capsule())
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, gutter)
        }
    }
}

struct ChartRow: View {
    let rank: Int
    let track: SCTrack
    let player: PlayerEngine
    let context: [SCTrack]

    @State private var hovering = false
    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 30, weight: .black))
                .fontWidth(.compressed)
                .monospacedDigit()
                .foregroundStyle(rank <= 3 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.35)))
                .frame(width: 42, alignment: .trailing)

            Artwork(url: track.artworkURL.scArtwork("t300x300"))
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                NavigationLink(value: track.user) {
                    Text(track.artistLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            if isCurrent && player.isPlaying {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.tint)
            }
            if let plays = track.playbackCount {
                Text(countString(plays))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 52, alignment: .trailing)
            }
            Text(timeString(Double(track.duration) / 1000))
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { Task { await player.play(track, in: context) } }
        .trackContextMenu(track, player: player)
    }
}
