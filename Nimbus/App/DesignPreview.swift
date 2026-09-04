#if DEBUG
import SwiftUI

private func sampleTrack(_ id: Int, _ title: String, _ artist: String, _ album: String, _ genre: String,
                         _ ms: Int, _ plays: Int, _ likes: Int, _ comments: Int, _ reposts: Int) -> SCTrack {
    let json = """
    {"id":\(id),"title":"\(title)","duration":\(ms),"permalink_url":"x",\
    "artwork_url":null,"user":{"id":\(id * 100),"username":"\(artist)"},"media":{"transcodings":[]},\
    "track_authorization":"","genre":"\(genre)","playback_count":\(plays),"likes_count":\(likes),\
    "comment_count":\(comments),"reposts_count":\(reposts),"publisher_metadata":{"album_title":"\(album)"}}
    """
    return try! JSONDecoder().decode(SCTrack.self, from: Data(json.utf8))
}

private let sampleTracks = [
    sampleTrack(1, "Midnight City", "M83", "Hurry Up, We're Dreaming", "Electronic", 243_000, 1_254_199, 24_921, 165, 3_204),
    sampleTrack(2, "Nightcall", "Kavinsky", "OutRun", "Synthwave", 258_000, 301_552, 4_668, 50, 812),
    sampleTrack(3, "Instant Crush", "Daft Punk", "Random Access Memories", "", 337_000, 8_204, 612, 7, 44),
    sampleTrack(4, "Genesis", "Grimes", "", "Art Pop", 254_000, 512, 43, 0, 2),
]

private func pillPreview(scrubbing: Bool) -> some View {
    PlayerPillContent(
        track: sampleTracks[0], isPlaying: true, currentTime: 78, duration: 243,
        isShuffled: true, repeatMode: .all, canPrevious: true, canNext: true,
        volume: .constant(0.7), isLiked: true, onToggle: {}, onSeek: { _ in },
        forceScrubbing: scrubbing,
        forceVolumeExpanded: scrubbing)
    .frame(maxWidth: 780)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .frame(width: 1000)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}











#Preview("Logo options") {
    VStack(spacing: 30) {
        HStack(alignment: .top, spacing: 30) {
            MarkTile(size: 200)
            MarkTile(size: 200, cornerRadius: 46)
            VStack(spacing: 14) {
                NimbusMark(letter: .primary, knob: .scOrange)
                    .frame(width: 96, height: 96)
                NimbusMark(letter: .primary, knob: .primary)
                    .frame(width: 96, height: 96)
            }
        }
        HStack(alignment: .bottom, spacing: 30) {
            ForEach([48.0, 32.0, 24.0, 16.0], id: \.self) { size in
                VStack(spacing: 8) {
                    MarkTile(size: size)
                    Text("\(Int(size))")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
    .padding(34)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Welcome") {
    WelcomeView(model: AppModel())
        .frame(width: 560, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.scOrange)
}

private struct LikesPreview: View {
    private let model: AppModel = {
        let model = AppModel()
        model.library.likes.seedForPreview(sampleTracks)
        model.player.seedForPreview(sampleTracks)
        return model
    }()

    var body: some View {
        LikesView(model: model, previewLayout: .list)
            .environment(model.library)
            .adaptiveMetrics()
            .frame(width: 940, height: 620)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(.scOrange)
    }
}

#Preview("Likes") { LikesPreview() }

private struct QueuePreview: View {
    private let player: PlayerEngine = {
        let engine = PlayerEngine(api: SoundCloudAPI())
        engine.seedForPreview(sampleTracks)
        return engine
    }()

    var body: some View {
        QueuePanel(player: player, onClose: { },
                   previewDrag: (id: sampleTracks[1].id, y: 140))
            .frame(width: 320, height: 460)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(.scOrange)
    }
}

#Preview("Queue") { QueuePreview() }



#Preview("Player pill") {
    VStack(spacing: 20) {
        pillPreview(scrubbing: false)
        pillPreview(scrubbing: true)
    }
    .padding(.vertical, 20)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Library") {
    let player = PlayerEngine(api: SoundCloudAPI())
    return NavigationSplitView {
        List {
            Section("Library") {
                Label("Likes", systemImage: "heart")
                Label("Playlists", systemImage: "music.note.list")
                Label("History", systemImage: "clock")
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } detail: {
        TrackTable(tracks: sampleTracks, player: player)
        .safeAreaInset(edge: .bottom) {
            PlayerPillContent(
                track: sampleTracks[0], isPlaying: true, currentTime: 78, duration: 243,
                volume: .constant(0.7), onToggle: {}, onSeek: { _ in })
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }
    .frame(width: 1080, height: 600)
    .tint(.scOrange)
}






private struct SidebarPreview: View {
    @State private var section: LibrarySection? = .likes

    var body: some View {
        SidebarNav(section: $section)
            .frame(width: 212, height: 430)
        .tint(.scOrange)
    }
}

#Preview("Sidebar") { SidebarPreview() }

private struct CardScalePreview: View {
    private let player = PlayerEngine(api: SoundCloudAPI())

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column(width: 868, label: "queue open")
            Divider()
            column(width: 1188, label: "queue closed")
        }
        .frame(height: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.scOrange)
    }

    private func column(width: CGFloat, label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(label) — \(Int(width))pt -> card \(Int(ContentMetrics(usable: width - gutter * 2).card))pt")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, gutter)
            Shelf {
                ForEach(sampleTracks) { track in
                    TrackCard(track: track, player: player, context: sampleTracks)
                }
            }
            ArtistShelfPreviewRow()
        }
        .padding(.vertical, 12)
        .frame(width: width, alignment: .leading)
        .environment(\.metrics, ContentMetrics(usable: width - gutter * 2))
    }
}

private struct ArtistShelfPreviewRow: View {
    var body: some View {
        Shelf(spacing: 20) {
            ForEach(sampleTracks) { track in
                ArtistCircle(artist: track.user)
            }
        }
    }
}

#Preview("Card scale") { CardScalePreview() }

private let samplePlaylist: SCPlaylist = {
    let json = """
    {"id":9001,"title":"Related tracks: U Know My Steez","artwork_url":null,"track_count":21,\
    "tracks":[],"user":{"id":77,"username":"WHITENER"},"description":"Based on WHITENER — U Know My Steez",\
    "is_album":false,"kind":"playlist","duration":4200000}
    """
    return try! JSONDecoder().decode(SCPlaylist.self, from: Data(json.utf8))
}()

private struct HomeBlocksPreview: View {
    private let model = AppModel()

    var body: some View {
        VStack(spacing: 24) {
            block(width: 1188, label: "queue closed")
            block(width: 868, label: "queue open")
        }
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.scOrange)
    }

    private func block(width: CGFloat, label: String) -> some View {
        let metrics = ContentMetrics(usable: width - gutter * 2)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(label) — \(Int(width))pt -> hero \(Int(metrics.hero))pt")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, gutter)
            FeaturedMix(playlist: samplePlaylist, eyebrow: "More of what you like", model: model)
        }
        .frame(width: width)
        .environment(\.metrics, metrics)
    }
}

#Preview("Home blocks") { HomeBlocksPreview() }

private let sampleWaveform: Waveform = {
    let samples = (0..<420).map { index -> Int in
        let t = Double(index)
        let value = 45 + 38 * abs(sin(t / 9)) * (0.55 + 0.45 * cos(t / 37))
        return Int(max(6, min(99, value)))
    }
    let json = "{\"height\":100,\"samples\":[\(samples.map(String.init).joined(separator: ","))]}"
    return Waveform(data: Data(json.utf8))!
}()

#Preview("Waveform") {
    VStack(alignment: .leading, spacing: 22) {
        label("idle — played 35%")
        WaveformView(waveform: sampleWaveform, progress: 0.35).frame(height: 56)

        label("hover ahead (70%)")
        WaveformView(waveform: sampleWaveform, progress: 0.35, hoverProgress: 0.7).frame(height: 56)

        label("hover behind (30% of 70% played)")
        WaveformView(waveform: sampleWaveform, progress: 0.7, hoverProgress: 0.3).frame(height: 56)
    }
    .padding(20)
    .frame(width: 760)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}

@ViewBuilder
private func label(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
}

#endif
