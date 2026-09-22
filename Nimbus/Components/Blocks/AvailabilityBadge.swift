import SwiftUI

extension SCTrack {
    /// What the site says about a track this account cannot play, or nil when it can.
    var lockNote: String? {
        switch availability {
        case .playable: nil
        case .subscription: "Available with SoundCloud Go+"
        case .region: "Not available in your country"
        }
    }
}

/// The mark beside a title the account cannot play, the way the site marks it: GO+ for a track
/// behind the subscription, a plain "Not available" for one locked to other countries.
struct AvailabilityBadge: View {
    let track: SCTrack
    /// Over a cover, where a translucent grey chip vanished on a light one.
    var onArtwork = false

    var body: some View {
        switch track.availability {
        case .playable:
            EmptyView()
        case .subscription:
            Text("GO+")
                .font(.system(size: 9, weight: .heavy))
                .kerning(0.3)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(GoPlus.gradient, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .help(track.lockNote ?? "")
        case .region:
            Text("Not available")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(onArtwork ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(onArtwork ? AnyShapeStyle(.black.opacity(0.6)) : AnyShapeStyle(.primary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .help(track.lockNote ?? "")
        }
    }
}

/// The site's Go+ colours, read off its track page: one diagonal pink ramp for the mark and the
/// banner both.
enum GoPlus {
    static let gradient = LinearGradient(
        colors: [Color(red: 0xC0 / 255, green: 0x28 / 255, blue: 0x6A / 255),
                 Color(red: 0xFF / 255, green: 0x3E / 255, blue: 0x8E / 255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let page = URL(string: "https://soundcloud.com/go")!
}

/// Under a locked track's hero, where the site puts it: what Go+ gives and the way to it, or,
/// for a track kept from this country, just that.
struct LockedTrackBanner: View {
    let track: SCTrack

    @Environment(\.openURL) private var openURL

    var body: some View {
        switch track.availability {
        case .playable:
            EmptyView()
        case .subscription:
            HStack(spacing: 16) {
                Text("Offline and ad-free listening to everything from mainstream releases to DJ sets and remixes.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button { openURL(GoPlus.page) } label: {
                    Text("Listen with Go+")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 53)
            .background(GoPlus.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .region:
            Text("This track isn't available in your country.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 53, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

extension View {
    /// Dims what a locked track shows, as the site greys a row it will not play.
    func lockedLook(_ track: SCTrack) -> some View {
        opacity(track.isPlayable ? 1 : 0.45)
    }
}

#if DEBUG
#Preview("Locked tracks") {
    let model = AppModel()
    let tracks = [nil, "SNIP", "BLOCK"].enumerated().map { index, policy in
        try! JSONDecoder().decode(SCTrack.self, from: Data("""
        {"id":\(index + 1),"title":"Track \(index + 1)","duration":214000,"permalink_url":"x",
         "artwork_url":null,"user":{"id":9,"username":"CODE80"},"media":{"transcodings":[]},
         "track_authorization":"","playback_count":4321,"genre":"Hip-hop & Rap",
         "created_at":"2024-10-18T00:00:00Z"\(policy.map { ",\"policy\":\"\($0)\"" } ?? "")}
        """.utf8))
    }
    return VStack(alignment: .leading, spacing: 18) {
        ForEach(tracks) { track in
            TrackRow(track: track, player: model.player, queue: .exactly(tracks))
        }
        ForEach(tracks) { track in
            LikeCard(track: track, player: model.player, queue: .exactly(tracks))
        }
        HStack(alignment: .top, spacing: 18) {
            ForEach(tracks) { track in
                TrackCard(track: track, player: model.player, queue: .exactly(tracks))
                    .frame(width: 180)
            }
        }
        ForEach(tracks) { track in
            LockedTrackBanner(track: track)
        }
    }
    .padding(24)
    .frame(width: 900)
    .environment(model.library)
    .tint(.scOrange)
}
#endif
