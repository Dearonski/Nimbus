import SwiftUI

/// Decides which timed comments are up: each one surfaces as playback reaches its moment and
/// lingers a few seconds, at most three at a time.
@MainActor
@Observable
final class CommentTicker {
    struct Shown: Identifiable, Equatable {
        let comment: SCComment
        let at: Date
        var id: String { comment.urn }
    }

    private(set) var shown: [Shown] = []

    @ObservationIgnored private var trackID: Int?
    @ObservationIgnored private var lastTime: Double?
    @ObservationIgnored private var lastPop: Date = .distantPast

    private static let limit = 3
    private static let lifetime: TimeInterval = 7
    /// A burst — a drop everyone reacts to, or the pile every track has at 0:00 — shows one at a time.
    private static let spacing: TimeInterval = 1.2
    /// A jump past this is a seek, and what it skipped over isn't news.
    private static let seekJump: Double = 2

    func advance(track: SCTrack?, time: Double, comments: [SCComment], now: Date = .now) {
        if track?.id != trackID {
            trackID = track?.id
            lastTime = nil
            shown = []
        }
        shown.removeAll { now.timeIntervalSince($0.at) > Self.lifetime }
        defer { lastTime = time }
        guard let lastTime, time >= lastTime, time - lastTime <= Self.seekJump,
              now.timeIntervalSince(lastPop) >= Self.spacing else { return }
        let passed = comments.filter {
            let at = Double($0.trackTime) / 1000
            return at > lastTime && at <= time
        }
        // The most liked of a burst rather than whichever sorts first.
        guard let next = passed.max(by: { $0.likes < $1.likes }),
              !shown.contains(where: { $0.comment.urn == next.urn }) else { return }
        shown.append(Shown(comment: next, at: now))
        if shown.count > Self.limit { shown.removeFirst(shown.count - Self.limit) }
        lastPop = now
    }
}

/// The stack over the title: the newest closest to it, the older ones above and fading.
struct FullPlayerComments: View {
    let shown: [CommentTicker.Shown]
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                bubble(item.comment)
                    .opacity([1, 0.6, 0.3][min(shown.count - 1 - index, 2)])
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .animation(.snappy(duration: 0.35), value: shown.map(\.id))
    }

    private func bubble(_ comment: SCComment) -> some View {
        HStack(spacing: 10 * scale) {
            Artwork(comment.user, size: .thumb)
                .frame(width: 28 * scale, height: 28 * scale)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6 * scale) {
                    Text(comment.user.username).font(.system(size: 12 * scale, weight: .semibold))
                    Text(timeString(Double(comment.trackTime) / 1000))
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(.white.opacity(0.5))
                        .monospacedDigit()
                }
                Text(comment.body)
                    .font(.system(size: 13.5 * scale))
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
        }
        .padding(.leading, 6 * scale)
        .padding(.trailing, 14 * scale)
        .padding(.vertical, 6 * scale)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 22 * scale, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22 * scale, style: .continuous).strokeBorder(.white.opacity(0.14)))
    }
}
