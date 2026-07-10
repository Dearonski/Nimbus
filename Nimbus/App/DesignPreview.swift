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
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }
    .frame(width: 1080, height: 600)
    .tint(.scOrange)
}
#endif
