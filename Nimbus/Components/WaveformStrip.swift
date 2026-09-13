import SwiftUI

/// What the hovered comment's line may do. A list card leaves this nil: there is no comment field
/// to reply into, so its line only reads.
struct WaveformCommentActions {
    var state: (SCComment) -> TrackPageModel.CommentState
    var toggleLike: (SCComment) -> Void
    var reply: (SCComment) -> Void
}

/// Comments for a track that isn't the page you're on — a card in a list loads its own, because
/// only the track page has a `TrackPageModel`.
@MainActor
@Observable
final class WaveformCommentsLoader {
    private(set) var comments: [SCComment] = []
    private var loadedID: Int?

    private final class Box {
        let comments: [SCComment]
        init(_ comments: [SCComment]) { self.comments = comments }
    }
    private static let cache = NSCache<NSString, Box>()

    /// Call from `.task`, so that scrolling a card away cancels the wait and the request with it.
    func load(_ track: SCTrack, api: SoundCloudAPI) async {
        guard loadedID != track.id else { return }
        loadedID = track.id
        comments = []
        // The count rides along with the track, so a silent track costs no request at all.
        guard (track.commentCount ?? 0) > 0 else { return }

        if let cached = Self.cache.object(forKey: track.urn as NSString) {
            comments = cached.comments
            return
        }
        // A beat before asking — only when it really means a request. Flinging through a long feed
        // would otherwise fire one per card swept past, each answered after the card is gone.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else {
            loadedID = nil
            return
        }
        // By position rather than by date: the faces are spread along the strip, and a popular
        // track's newest comments all sit on the same few seconds.
        guard let page = try? await api.trackComments(trackURN: track.urn, sort: .timestamp, first: 30)
        else { return }
        guard loadedID == track.id else { return }
        Self.cache.setObject(Box(page.comments), forKey: track.urn as NSString)
        comments = page.comments
    }

#if DEBUG
    static func seedCache(_ urn: String, _ comments: [SCComment]) {
        cache.setObject(Box(comments), forKey: urn as NSString)
    }
#endif
}

/// The waveform as every screen uses it: the bars, the seek preview under the pointer, the time
/// badges, and the comment faces sitting on the second they were left at.
struct WaveformStrip: View {
    enum Badges {
        /// Time top right, duration bottom right — the track page's own layout.
        case corners
        /// Both along the bottom, lifted clear of the reflection: what a list card has room for.
        case insetBottom
    }

    struct Style {
        var remainingColor: Color = .primary
        /// The size a face reaches with the pointer on the strip.
        var faceSize: CGFloat = 20
        /// How a face sits until the pointer finds it. On a list card the faces are decoration
        /// until you go looking for them, so they shrink back and fade the way the site's do; the
        /// track page is where comments are the point, and keeps them at full size.
        var restingFace: (scale: CGFloat, opacity: Double) = (0.6, 0.45)
        /// Only the face under the pointer grows — its neighbours stay as they were.
        var hoverFaceScale: CGFloat = 1
        /// Distance from the line where the bars end down to the top of a resting face. A list card
        /// hangs them straight off the line; the track page has the room to let them breathe.
        var faceTopGap: CGFloat = 0
        var badges: Badges = .insetBottom

        static let hero = Style(remainingColor: .white, faceSize: 30, restingFace: (1, 1),
                                hoverFaceScale: 1.15, faceTopGap: 5, badges: .corners)
        static let card = Style()
    }

    let track: SCTrack
    var progress: Double = 0
    var currentTime: Double = 0
    var isCurrent = false
    var comments: [SCComment] = []
    var actions: WaveformCommentActions?
    var style: Style = .card
    /// A preview has no pointer, so the comment line is otherwise impossible to look at.
    var previewComment: SCComment?
    let onScrub: (Double) -> Void

    @State private var waveform = WaveformLoader()
    @State private var size = CGSize(width: 1, height: 1)
    @State private var hoverX: CGFloat?
    /// Holds the line open while the pointer is on it — otherwise its own buttons would be
    /// unreachable, because moving towards them changes which comment is nearest.
    @State private var pinned: SCComment?
    @State private var lineWidth: CGFloat = 0

    private var duration: Double { Double(track.duration) / 1000 }

    private var hoverProgress: Double {
        guard let hoverX else { return 0 }
        return min(max(hoverX / size.width, 0), 1)
    }

    var body: some View {
        WaveformView(waveform: waveform.waveform,
                     progress: progress,
                     // No seek preview on a track that isn't playing: there is nothing to move,
                     // and the orange run-up read as progress that isn't there.
                     hoverProgress: isCurrent ? hoverProgress : 0,
                     remainingColor: style.remainingColor,
                     highlight: isCurrent || hoverX == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.18), value: hoverX == nil)
            .contentShape(Rectangle())
            .overlay { badges }
            .overlay { commentFaces }
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                size = CGSize(width: max($0.width, 1), height: max($0.height, 1))
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = min(max(point.x, 0), size.width)
                case .ended: hoverX = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onEnded {
                onScrub(min(max($0.location.x / size.width, 0), 1))
            })
            .task(id: track.id) { waveform.load(track.waveformURL) }
    }

    // MARK: - Time

    @ViewBuilder
    private var badges: some View {
        switch style.badges {
        case .corners:
            ZStack {
                badge(timeString(currentTime), tinted: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                badge(timeString(duration), tinted: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        case .insetBottom:
            ZStack {
                // Top left rather than bottom left: down there it lands under the first comment's
                // face, and a track commented at 0:05 hid its own playhead time.
                if isCurrent {
                    badge(timeString(currentTime), tinted: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                badge(timeString(duration), tinted: false)
                    .padding(.bottom, reflectionZone)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    /// Height of the reflection plus the centre gap — badges sit on the upright half, clear of the
    /// mirrored bars below it.
    private var reflectionZone: CGFloat { size.height - WaveformView.barsBottom(in: size.height) }

    /// Light text on a dark plate in both appearances: the plate is what keeps the time legible
    /// over the bars, so the label can't follow the theme the way the bars do.
    private func badge(_ text: String, tinted: Bool) -> some View {
        Text(text)
            .font(.system(size: style.badges == .corners ? 10.5 : 10)).monospacedDigit()
            .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.8)))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Comments

    /// Kept a full radius inside the strip: comments land on 0:00 constantly, and a face centred
    /// there is cut in half by the edge.
    private func x(of comment: SCComment) -> CGFloat {
        let exact = size.width * min(max(Double(comment.trackTime) / 1000 / max(duration, 0.001), 0), 1)
        let inset = style.faceSize / 2
        return min(max(exact, inset), max(size.width - inset, inset))
    }

    /// Faces this size can't be told apart once they overlap, so a cluster of comments on the same
    /// few seconds shows only the first of them.
    private var visibleComments: [SCComment] {
        guard duration > 0, size.width > 1 else { return [] }
        var lastX = -CGFloat.greatestFiniteMagnitude
        return comments.sorted { $0.trackTime < $1.trackTime }.filter { comment in
            guard x(of: comment) - lastX >= style.faceSize * 0.7 else { return false }
            lastX = x(of: comment)
            return true
        }
    }

    /// The comment nearest the pointer, picked from the strip rather than from each avatar's own
    /// hover: faces are small and set close together, so a pointer sliding between two of them
    /// used to leave the previous line standing.
    private var hoveredComment: SCComment? {
        if let previewComment { return previewComment }
        if let pinned { return pinned }
        guard let hoverX, duration > 0 else { return nil }
        let nearest = visibleComments.min { first, second in
            abs(x(of: first) - hoverX) < abs(x(of: second) - hoverX)
        }
        guard let nearest, abs(x(of: nearest) - hoverX) <= style.faceSize else { return nil }
        return nearest
    }

    /// Faces sit on the second they were left at — the whole point of SoundCloud comments. They
    /// take no clicks of their own: the strip underneath already seeks to the same spot.
    private var commentFaces: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibleComments) { comment in
                let isHovered = hoveredComment?.urn == comment.urn
                Artwork(comment.user, size: .thumb)
                    .frame(width: style.faceSize, height: style.faceSize)
                    .clipShape(Circle())
                    .overlay {
                        // The tint ring marks the one being pointed at, the way the site does. The
                        // others still need a hairline in the strip's own colour: faded to 0.4 over
                        // a light window, a face otherwise disappears into the background.
                        Circle().strokeBorder(isHovered ? AnyShapeStyle(.tint)
                                                        : AnyShapeStyle(style.remainingColor.opacity(0.25)),
                                              lineWidth: isHovered ? 2 : 1)
                    }
                    // Anchored to the bottom so a face grows upwards out of its line instead of
                    // down into the comment line's slot.
                    .scaleEffect(isHovered ? style.hoverFaceScale : style.restingFace.scale,
                                 anchor: .bottom)
                    .opacity(isHovered ? 1 : style.restingFace.opacity)
                    .position(x: x(of: comment), y: faceCentreY)
                    .animation(.snappy(duration: 0.14), value: isHovered)
                    // Faces overlap where comments cluster, and the line runs across the ones to its
                    // right; the hovered face has to stay on top of both.
                    .zIndex(isHovered ? 2 : 0)
                    .allowsHitTesting(false)
            }

            if let hoveredComment {
                commentLine(for: hoveredComment).zIndex(1)
            }
        }
    }

    /// The hovered comment's line lives along the bottom of the strip. Nothing about a comment is
    /// ever drawn outside the strip, so hovering can't cover the title, the action row or anything
    /// else on the card — which is what the site does too.
    private static let lineSlot: CGFloat = 19

    /// Faces hang off the line where the bars end, dipping into the reflection, as on the site. On
    /// a short strip the comment line runs across the ones to its right; those are the faces you are
    /// not reading, and the hovered one is drawn above it.
    ///
    /// The frame is `faceSize` tall but a resting face is drawn at `restingFace.scale` of it from
    /// the bottom edge, so placing its *visible* top on the line means working back from that edge.
    private var faceCentreY: CGFloat {
        let restingHeight = style.faceSize * style.restingFace.scale
        let top = WaveformView.barsBottom(in: size.height) + style.faceTopGap
        let centre = top + restingHeight - style.faceSize / 2
        return min(max(centre, style.faceSize / 2), size.height - style.faceSize / 2)
    }

    /// One line, like the site's: name, comment, and — where there is something to press — Reply and
    /// the like count. A long comment is cut rather than wrapped; the full text is in the list.
    private func commentLine(for comment: SCComment) -> some View {
        HStack(spacing: 6) {
            Text(comment.user.username)
                .font(.system(size: 11, weight: .semibold))
                .layoutPriority(1)
            Text(comment.body)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.82))

            if let actions {
                let state = actions.state(comment)
                Text("·").foregroundStyle(.white.opacity(0.4))
                Button("Reply") { actions.reply(comment) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                Button { actions.toggleLike(comment) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: state.liked ? "heart.fill" : "heart")
                        if state.likes > 0 { Text("\(state.likes)").monospacedDigit() }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(state.liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lineWidth = $0 }
        // The plate has to hug its text, so the width limit goes outside the background: inside it,
        // `maxWidth` stretched a three-word comment into a bar across the whole strip.
        .frame(maxWidth: lineMaxWidth(for: comment), alignment: .leading)
        .onHover { pinned = $0 ? comment : nil }
        .offset(x: lineX(for: comment), y: size.height - Self.lineSlot)
        .allowsHitTesting(actions != nil)
    }

    /// The line starts at its face and runs towards the end of the strip, stopping short of the
    /// duration badge; a comment near the end slides its line back left instead of running past the
    /// edge, and a long one is cut.
    private func lineMaxWidth(for comment: SCComment) -> CGFloat {
        let toBadge = size.width - lineStart(for: comment) - Self.durationBadgeRoom
        return max(min(toBadge, size.width - Self.durationBadgeRoom), min(size.width, 180))
    }

    private static let durationBadgeRoom: CGFloat = 40

    /// Clear of its own face: on a short strip the face and the line share a row, and starting the
    /// plate under the avatar ate the first word of the name.
    private func lineStart(for comment: SCComment) -> CGFloat {
        max(x(of: comment) + style.faceSize / 2 + 3, 0)
    }

    private func lineX(for comment: SCComment) -> CGFloat {
        min(lineStart(for: comment), max(size.width - lineWidth, 0))
    }
}

#if DEBUG
let previewWaveURL = "preview://strip"

func previewStripTrack(comments: Int) -> SCTrack {
    let samples = (0..<420).map { index -> Int in
        let t = Double(index)
        return Int(max(6, min(99, 45 + 38 * abs(sin(t / 9)) * (0.55 + 0.45 * cos(t / 37)))))
    }
    WaveformLoader.seedCache(previewWaveURL,
                             json: "{\"height\":100,\"samples\":[\(samples.map(String.init).joined(separator: ","))]}")
    return try! JSONDecoder().decode(SCTrack.self, from: Data("""
    {"id":1,"title":"6AM","duration":183224,"permalink_url":"x","artwork_url":null,
     "waveform_url":"\(previewWaveURL)","user":{"id":9,"username":"OG Buda"},
     "media":{"transcodings":[]},"track_authorization":"","comment_count":\(comments)}
    """.utf8))
}

#Preview("Waveform strip") {
    let model = AppModel()
    let track = previewStripTrack(comments: 4)
    let page = TrackPageModel(track: track, api: model.api)
    let comments = [
        sampleComment(1, "Кирилл Мельников", "легенда", 6955, likes: 3),
        sampleComment(2, "FAX UT", "лучший трек года, серьёзно", 39650),
        sampleComment(3, "DJ 7up", "только мы вдвоем", 105993, likes: 12),
        sampleComment(4, "darinkas", "🔥", 148000),
    ]
    page.seedForPreview(comments: comments)

    return VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 26) {
            Text("hero — faces always on, line with actions")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            WaveformStrip(track: track, progress: 0.42, currentTime: 77, isCurrent: true,
                          comments: comments,
                          actions: WaveformCommentActions(state: page.state(for:),
                                                          toggleLike: page.toggleLike,
                                                          reply: page.beginReply(to:)),
                          style: .hero,
                          previewComment: comments[2]) { _ in }
                .frame(height: 130)
                .padding(.bottom, 70)
        }
        .padding(24)
        .frame(width: 820)
        .background(Color.black.opacity(0.85))

        VStack(alignment: .leading, spacing: 26) {
            Text("list card at rest — faces small and faded")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            WaveformStrip(track: track, progress: 0.42, currentTime: 77, isCurrent: true,
                          comments: comments) { _ in }
                .frame(height: 48)

            Text("list card — only the hovered face grows, line reads only")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            WaveformStrip(track: track, progress: 0.42, currentTime: 77, isCurrent: true,
                          comments: comments,
                          previewComment: comments[1]) { _ in }
                .frame(height: 48)
                .padding(.bottom, 70)
        }
        .padding(24)
        .frame(width: 820)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .environment(model.library)
    .tint(.scOrange)
}
#endif
