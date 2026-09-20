import Nuke
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
    private var comments: [SCComment] = []

    private static func key(_ urn: String, _ first: Int) -> NSString { "\(urn)#\(first)" as NSString }
    @ObservationIgnored private var loadedID: Int?
    @ObservationIgnored private var ownerID: Int?
    @ObservationIgnored private var first = 30

    /// Asked per track rather than read as state, for the reason `WaveformLoader.peaks(for:)` is.
    func comments(for track: SCTrack) -> [SCComment] {
        // Read before anything can return: a body that never touched it is not redrawn when the fetch lands.
        let loaded = comments
        if ownerID == track.id { return loaded }
        return Self.cache.object(forKey: Self.key(track.urn, first))?.comments ?? []
    }

    private final class Box {
        let comments: [SCComment]
        init(_ comments: [SCComment]) { self.comments = comments }
    }
    private static let cache = NSCache<NSString, Box>()

    /// Call from `.task`, so that scrolling a card away cancels the wait and the request with it.
    func load(_ track: SCTrack, api: SoundCloudAPI, first: Int = 30) async {
        guard loadedID != track.id else { return }
        loadedID = track.id
        self.first = first
        // The count rides along with the track, so a silent track costs no request at all.
        guard (track.commentCount ?? 0) > 0 else { return }
        // Cached comments are already on screen through `comments(for:)`.
        guard Self.cache.object(forKey: Self.key(track.urn, first)) == nil else { return }
        // A beat before asking — only when it really means a request. Flinging through a long feed
        // would otherwise fire one per card swept past, each answered after the card is gone.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else {
            loadedID = nil
            return
        }
        // Newest, not by position: TIMESTAMP starts at the beginning of the track and never gets
        // past it — measured 17.09.2026 on a track with 3197 comments, where the first 30 by
        // position (and the first 100) all sat on 0s, leaving the strip a single face. The newest
        // 30 spread across 73% of that track, the newest 60 across 95%.
        guard let page = try? await api.trackComments(trackURN: track.urn, sort: .newest, first: first)
        else { return }
        Self.cache.setObject(Box(page.comments), forKey: Self.key(track.urn, first))
        guard loadedID == track.id else { return }
        ownerID = track.id
        comments = page.comments
    }

#if DEBUG
    static func seedCache(_ urn: String, _ comments: [SCComment], first: Int = 30) {
        cache.setObject(Box(comments), forKey: key(urn, first))
    }
#endif
}

/// Avatars cut to the size they are drawn at: a `LazyImage` per face put thirty 100px bitmaps on every card.
@MainActor
@Observable
final class WaveformFaceImages {
    private(set) var images: [URL: Image] = [:]
    private(set) var failed: Set<URL> = []
    private(set) var version = 0

    func load(_ urls: [URL], pixels: CGFloat) async {
        // A recycled cell keeps this loader across tracks; without the sweep it collects every face it
        // ever drew. Past a threshold, not per track: each sweep is a write, and a write redraws the card.
        let wanted = Set(urls)
        if images.count > 90 {
            images = images.filter { wanted.contains($0.key) }
            version += 1
        }
        let missing = Set(urls).filter { images[$0] == nil && !failed.contains($0) }
        guard !missing.isEmpty else { return }
        let side = CGSize(width: pixels, height: pixels)
        var arrived: [URL: Image] = [:]
        var dead: Set<URL> = []
        var lastPublish = ContinuousClock.now

        await withTaskGroup(of: (URL, Result<NSImage, any Error>).self) { group in
            for url in missing {
                group.addTask {
                    let request = ImageRequest(url: url, processors: [.resize(size: side, unit: .pixels, crop: true), .circle()])
                    do {
                        return (url, .success(try await ImagePipeline.shared.image(for: request)))
                    } catch {
                        return (url, .failure(error))
                    }
                }
            }
            for await (url, result) in group {
                switch result {
                case .success(let image):
                    arrived[url] = Image(nsImage: image)
                case .failure(let error):
                    DeadArtwork.record(error, for: url)
                    if DeadArtwork.contains(url) { dead.insert(url) }
                }
                // In batches: each arrival published on its own redrew the strip once per face.
                if ContinuousClock.now - lastPublish > .milliseconds(120) {
                    publish(&arrived, &dead)
                    lastPublish = .now
                }
            }
        }
        publish(&arrived, &dead)
    }

    private func publish(_ arrived: inout [URL: Image], _ dead: inout Set<URL>) {
        guard !arrived.isEmpty || !dead.isEmpty else { return }
        images.merge(arrived) { _, new in new }
        failed.formUnion(dead)
        version += 1
        arrived = [:]
        dead = []
    }
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
        /// Closest two faces may sit before the later one is dropped. Measured off the site
        /// 17.09.2026: it crowds faces shoulder to shoulder rather than thinning them out — 201
        /// of them over 751pt on a busy track, and on a quiet one neighbours 1pt apart. The track
        /// page shows everything the API returns for the same reason; a list card has no room for
        /// that and keeps its faces apart.
        var minimumFaceGap: CGFloat = 14

        static let hero = Style(remainingColor: .white, faceSize: 30, restingFace: (1, 1),
                                hoverFaceScale: 1.15, faceTopGap: 5, badges: .corners,
                                minimumFaceGap: 1)
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
    @State private var faces = WaveformFaceImages()
    /// Faces that are views rather than canvas pixels: the hovered one, and those still shrinking back.
    @State private var lingering: [String: Int] = [:]
    @State private var hoveredURN: String?

    @Environment(\.displayScale) private var displayScale

    private var duration: Double { Double(track.duration) / 1000 }

    private var hoverProgress: Double {
        guard let hoverX else { return 0 }
        return min(max(hoverX / size.width, 0), 1)
    }

    private struct FaceRequest: Equatable {
        let urls: [URL]
        let pixels: CGFloat
    }

    var body: some View {
        let visible = visibleComments
        let hovered = hoveredComment(among: visible)
        let request = FaceRequest(urls: visible.compactMap(avatarURL),
                                  pixels: (style.faceSize * max(style.hoverFaceScale, 1) * displayScale).rounded(.up))
        WaveformView(waveform: waveform.peaks(for: track.waveformURL),
                     progress: progress,
                     // No seek preview on a track that isn't playing: there is nothing to move,
                     // and the orange run-up read as progress that isn't there.
                     hoverProgress: isCurrent ? hoverProgress : 0,
                     remainingColor: style.remainingColor,
                     highlight: isCurrent || hoverX == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.18), value: hoverX == nil)
            .contentShape(Rectangle())
            .overlay { badges }
            .overlay { commentFaces(visible, hovered: hovered) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                size = CGSize(width: max($0.width, 1), height: max($0.height, 1))
            }
            .onContinuousHover { phase in
                // Each hover fades the highlight in by redrawing all the bars per frame — see `ScrollActivity`.
                guard !ScrollActivity.isLive else {
                    if hoverX != nil { hoverX = nil }
                    return
                }
                switch phase {
                case .active(let point): hoverX = min(max(point.x, 0), size.width)
                case .ended: hoverX = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onEnded {
                onScrub(min(max($0.location.x / size.width, 0), 1))
            })
            .task(id: track.id) { await waveform.load(track.waveformURL) }
            .task(id: request) { await faces.load(request.urls, pixels: request.pixels) }
            // A recycled cell hands this strip to another track with the pointer state of the last one.
            .onChange(of: track.id) { _, _ in
                hoverX = nil
                pinned = nil
            }
            .onChange(of: hovered?.urn) { old, new in
                hoveredURN = new
                if let new { lingering[new, default: 0] += 1 }
                if let old { release(old) }
            }
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

    /// Faces crowd together the way the site's do; a second one on the very same pixel adds
    /// nothing but overdraw, so only that is dropped.
    private var visibleComments: [SCComment] {
        guard duration > 0, size.width > 1 else { return [] }
        var lastX = -CGFloat.greatestFiniteMagnitude
        return comments.sorted { $0.trackTime < $1.trackTime }.filter { comment in
            guard x(of: comment) - lastX >= style.minimumFaceGap else { return false }
            lastX = x(of: comment)
            return true
        }
    }

    /// The comment nearest the pointer, picked from the strip rather than from each avatar's own
    /// hover: faces are small and set close together, so a pointer sliding between two of them
    /// used to leave the previous line standing.
    private func hoveredComment(among visible: [SCComment]) -> SCComment? {
        if let previewComment { return previewComment }
        if let pinned { return pinned }
        guard let hoverX, duration > 0 else { return nil }
        let nearest = visible.min { first, second in
            abs(x(of: first) - hoverX) < abs(x(of: second) - hoverX)
        }
        guard let nearest, abs(x(of: nearest) - hoverX) <= style.faceSize else { return nil }
        return nearest
    }

    private func avatarURL(_ comment: SCComment) -> URL? {
        comment.user.avatarURL.liveArtwork.scArtwork(.thumb)
    }

    /// Faces sit on the second they were left at — the whole point of SoundCloud comments. They
    /// take no clicks of their own: the strip underneath already seeks to the same spot.
    private func commentFaces(_ visible: [SCComment], hovered: SCComment?) -> some View {
        let side = style.faceSize * style.restingFace.scale
        let bottom = faceCentreY + style.faceSize / 2
        let live = visible.filter { $0.urn == hovered?.urn || lingering[$0.urn] != nil }
        let liveURNs = Set(live.map(\.urn))
        let resting = visible.filter { !liveURNs.contains($0.urn) }.map { comment in
            WaveformFacesCanvas.Face(
                rect: CGRect(x: x(of: comment) - side / 2, y: bottom - side, width: side, height: side),
                url: avatarURL(comment),
                gradient: SCGradient.index(for: comment.user.id))
        }
        return ZStack(alignment: .topLeading) {
            WaveformFacesCanvas(faces: resting, images: faces.images, failed: faces.failed,
                                version: faces.version, opacity: style.restingFace.opacity,
                                ring: style.remainingColor.opacity(0.25),
                                ringWidth: style.restingFace.scale)
                .equatable()
                .allowsHitTesting(false)

            ForEach(live) { comment in
                let isHovered = hovered?.urn == comment.urn
                let url = avatarURL(comment)
                WaveformLiveFace(image: url.flatMap { faces.images[$0] },
                                 isMissing: url.map(faces.failed.contains) ?? true,
                                 gradient: SCGradient.index(for: comment.user.id),
                                 isHovered: isHovered, style: style,
                                 startsHovered: previewComment != nil)
                    .position(x: x(of: comment), y: faceCentreY)
                    // Faces overlap where comments cluster, and the line runs across the ones to its
                    // right; the hovered face has to stay on top of both.
                    .zIndex(isHovered ? 2 : 0)
                    .allowsHitTesting(false)
            }

            if let hovered {
                commentLine(for: hovered).zIndex(1)
            }
        }
    }

    /// Hands a face back to the canvas once it has finished shrinking, unless the pointer returned.
    private func release(_ urn: String) {
        let token = lingering[urn]
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard lingering[urn] == token, hoveredURN != urn else { return }
            lingering[urn] = nil
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

/// A face while the pointer is on it or it is still shrinking back; at rest it looks exactly like
/// its canvas twin, so the swap between the two is invisible.
struct WaveformLiveFace: View {
    let image: Image?
    let isMissing: Bool
    let gradient: Int
    let isHovered: Bool
    let style: WaveformStrip.Style

    // Starts at rest and grows on the first frame: inserted already hovered, it had nothing to animate from.
    @State private var hasAppeared: Bool

    init(image: Image?, isMissing: Bool, gradient: Int, isHovered: Bool,
         style: WaveformStrip.Style, startsHovered: Bool) {
        self.image = image
        self.isMissing = isMissing
        self.gradient = gradient
        self.isHovered = isHovered
        self.style = style
        _hasAppeared = State(initialValue: startsHovered)
    }

    var body: some View {
        let isActive = isHovered && hasAppeared
        Group {
            if let image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else if isMissing {
                SCGradient(index: gradient)
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: style.faceSize, height: style.faceSize)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(isActive ? AnyShapeStyle(.tint)
                                           : AnyShapeStyle(style.remainingColor.opacity(0.25)),
                                  lineWidth: isActive ? 2 : 1)
        }
        // Anchored to the bottom so a face grows upwards out of its line instead of down into
        // the comment line's slot.
        .scaleEffect(isActive ? style.hoverFaceScale : style.restingFace.scale, anchor: .bottom)
        .opacity(isActive ? 1 : style.restingFace.opacity)
        .animation(.snappy(duration: 0.14), value: isActive)
        .onAppear { hasAppeared = true }
    }
}

/// Every resting face of a strip in one drawing pass.
struct WaveformFacesCanvas: View, Equatable {
    nonisolated struct Face: Equatable {
        let rect: CGRect
        let url: URL?
        let gradient: Int
    }

    let faces: [Face]
    let images: [URL: Image]
    let failed: Set<URL>
    /// Stands in for `images` in `==`: `Image` is not Equatable.
    let version: Int
    let opacity: Double
    let ring: Color
    let ringWidth: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.faces == rhs.faces && lhs.version == rhs.version && lhs.opacity == rhs.opacity
            && lhs.ring == rhs.ring && lhs.ringWidth == rhs.ringWidth
    }

    var body: some View {
        Canvas { context, _ in
            context.opacity = opacity
            // Avatars arrive already round, so nothing here clips; rings and blanks go out as one path each.
            var rings = Path(), blanks = Path()
            for face in faces {
                let inset = face.rect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2)
                if let url = face.url, let image = images[url] {
                    context.draw(image, in: face.rect)
                } else if face.url.map(failed.contains) ?? true {
                    context.fill(Path(ellipseIn: face.rect), with: .linearGradient(
                        SCGradient.gradient(face.gradient),
                        startPoint: face.rect.origin,
                        endPoint: CGPoint(x: face.rect.maxX, y: face.rect.maxY)))
                } else if !overlaps {
                    blanks.addEllipse(in: face.rect)
                } else {
                    context.fill(Path(ellipseIn: face.rect), with: .color(.secondary.opacity(0.15)))
                }
                // Crowded faces keep their own ring: batched, a ring would land on top of the face covering it.
                if overlaps {
                    context.stroke(Path(ellipseIn: inset), with: .color(ring), lineWidth: ringWidth)
                } else {
                    rings.addEllipse(in: inset)
                }
            }
            if !blanks.isEmpty { context.fill(blanks, with: .color(.secondary.opacity(0.15))) }
            if !rings.isEmpty { context.stroke(rings, with: .color(ring), lineWidth: ringWidth) }
        }
    }

    private var overlaps: Bool {
        zip(faces, faces.dropFirst()).contains { $1.rect.minX < $0.rect.maxX }
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
