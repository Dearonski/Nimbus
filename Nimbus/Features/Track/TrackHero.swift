import SwiftUI

/// The block the track page opens with, laid out like soundcloud.com's own: play, title and byline
/// top left, the waveform across the rest, artwork on the right, and the comment field with the
/// track's actions along the bottom. Behind everything sits the artwork again, blurred — the same
/// treatment the artist banner uses, so the two pages read as one app.
struct TrackHero: View {
    let track: SCTrack
    let model: AppModel
    let page: TrackPageModel
    /// A preview has no pointer, so the bubble is otherwise impossible to look at.
    var previewComment: SCComment?

    @Environment(\.metrics) private var metrics
    @Environment(PageRoom.self) private var room: PageRoom?

    @State private var isPosting = false
    /// The strip shows comments where they were left, so it loads them by position and keeps them
    /// there — the list below is free to re-sort without the faces moving.
    @State private var waveComments = WaveformCommentsLoader()

    @FocusState private var fieldFocused: Bool

    private var isCurrent: Bool { track.id == model.player.currentTrack?.id }
    private var isPlaying: Bool { isCurrent && model.player.isPlaying }
    private var isLiked: Bool { model.library.isLiked(track) }
    private var isReposted: Bool { model.library.isReposted(track) }

    private var duration: Double { Double(track.duration) / 1000 }
    private var progress: Double {
        guard isCurrent, model.player.duration > 0 else { return 0 }
        return min(max(model.player.currentTime / model.player.duration, 0), 1)
    }
    /// Where a new comment lands: the playhead while this track is playing, the start otherwise.
    private var commentTime: Double { isCurrent ? model.player.currentTime : 0 }

    private var artworkSize: CGFloat {
        TrackDetailView.showsRail(in: room, usable: metrics.usable) ? TrackDetailView.railWidth : 240
    }

    /// Measured off the live page: a 130pt strip beside 336pt artwork. Tying it to the artwork
    /// keeps that ratio at every window size — left to fill the block, the waveform came out
    /// almost twice as tall as the site's.
    private var waveHeight: CGFloat { artworkSize * 0.39 }

    /// The block's own padding. Everything below the hero is inset by this too, so the artwork's
    /// right edge lines up with the rail beneath it — on the site those two edges are the same line.

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 0) {
                headline
                Spacer(minLength: 12)
                waveformStrip
                    .frame(height: waveHeight)
                    // The comment card hangs below the strip; without this the action row, which
                    // comes later in the stack, would be painted over it.
                    .zIndex(1)
                Spacer(minLength: 12)
                bottomBar
                if let failure = page.postFailure {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Artwork(track, size: .hero)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opensArtwork(track.coverURL, preview: .hero, title: track.title)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
        .padding(ContentMetrics.heroInset)
        .frame(minHeight: artworkSize + ContentMetrics.heroInset * 2)
        .background {
            // Cropped before the blur: a filled square cover would otherwise be blurred whole.
            Artwork(track, size: .hero)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 60, opaque: true)
                .overlay(Color.black.opacity(0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.snappy, value: artworkSize)
        .task(id: track.id) {
            guard previewComment == nil else { return }
            // 100 is what one request gives — the API caps `first` there, whatever is asked for.
            await waveComments.load(track, api: model.api, first: 100)
        }
    }

    private var headline: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                PlayFAB(size: 56, isPlaying: isPlaying)
            }
            .buttonStyle(PlayerButtonStyle())

            VStack(alignment: .leading, spacing: 5) {
                Text(track.title)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    NavButton(value: track.user) {
                        HStack(spacing: 5) {
                            Text(track.artistLine)
                            if track.user.verified == true {
                                Image(systemName: "checkmark.seal.fill").font(.system(size: 11))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if let genre = track.genre, !genre.isEmpty {
                        Text("· \(genre)")
                    }
                    if let age = track.ageLabel {
                        Text("· \(age)")
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    private var waveformStrip: some View {
        WaveformStrip(track: track,
                      progress: progress,
                      currentTime: isCurrent ? model.player.currentTime : 0,
                      isCurrent: isCurrent,
                      comments: waveComments.comments(for: track),
                      actions: WaveformCommentActions(state: page.state(for:),
                                                      toggleLike: page.toggleLike,
                                                      reply: page.beginReply(to:)),
                      style: .hero,
                      previewComment: previewComment,
                      onScrub: scrub)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            commentField
            Button { model.library.toggleLike(track) } label: {
                Label(countString(track.likesCount ?? 0), systemImage: isLiked ? "heart.fill" : "heart")
            }
            .glassButton(isLiked ? .prominent : .neutral)

            Button { model.library.toggleRepost(track) } label: {
                Label(countString(track.repostsCount ?? 0), systemImage: "arrow.2.squarepath")
            }
            .glassButton(isReposted ? .prominent : .neutral)

            if let url = URL(string: track.permalinkURL) {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .glassButton(.icon)
            }
            Menu {
                TrackMenuContent(track: track, player: model.player)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .glassButton(.icon)
            .fixedSize()
        }
        .controlSize(.large)
        .glassButtonRow()
    }

    private var commentField: some View {
        // Avatar and send button are both inset by the same amount the capsule leaves above and
        // below them, so the round shapes sit centred in it rather than drifting off one edge.
        let inset = (GlassMetrics.height(.large) - Self.fieldControlSize) / 2
        return HStack(spacing: 8) {
            Artwork(model.library.meUser, size: .thumb, placeholderOpacity: 0.25)
                .frame(width: Self.fieldControlSize, height: Self.fieldControlSize)
                .clipShape(Circle())

            TextField("Write a comment", text: Binding(get: { page.draft },
                                                       set: { page.draft = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($fieldFocused)
                .onSubmit(post)
                .onKeyPress(.escape) {
                    fieldFocused = false
                    return .handled
                }
                .reportsTyping(fieldFocused, to: model)
                .onChange(of: page.focusRequests) { _, _ in fieldFocused = true }

            Text(timeString(commentTime))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))

            sendButton
        }
        .padding(.horizontal, inset)
        .frame(height: GlassMetrics.height(.large))
        .frame(maxWidth: .infinity)
        .glassCapsule()
    }

    private static let fieldControlSize: CGFloat = 26

    private var canPost: Bool {
        !page.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPosting
    }

    private var sendButton: some View {
        Button(action: post) {
            ZStack {
                Circle().fill(canPost ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.14)))
                if isPosting {
                    FaderLoader(size: 14)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(canPost ? .white : .white.opacity(0.5))
                }
            }
            .frame(width: Self.fieldControlSize, height: Self.fieldControlSize)
        }
        .buttonStyle(.plain)
        .disabled(!canPost)
        .animation(.snappy(duration: 0.14), value: canPost)
        .help("Post at \(timeString(commentTime))")
    }

    private func post() {
        let text = page.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isPosting else { return }
        isPosting = true
        page.draft = ""
        Task {
            await page.post(text, at: Int(commentTime * 1000))
            isPosting = false
        }
    }

    private func play() {
        if isCurrent {
            model.player.togglePlayPause()
        } else {
            Task { await PlayQueue.exactly([track]).start(track, on: model.player) }
        }
    }

    private func scrub(to ratio: Double) {
        if isCurrent {
            model.player.seek(to: ratio * model.player.duration)
        } else {
            Task {
                await PlayQueue.exactly([track]).start(track, on: model.player)
                model.player.seek(to: ratio * duration)
            }
        }
    }
}

#if DEBUG
#Preview("Track hero") {
    let model = AppModel()
    let track = try! JSONDecoder().decode(SCTrack.self, from: Data("""
    {"id":1,"title":"6AM в Будапеште","duration":183224,"permalink_url":"https://soundcloud.com/x",
     "artwork_url":null,"user":{"id":9,"username":"OG Buda","verified":true},
     "media":{"transcodings":[]},"track_authorization":"","genre":"Hip-hop & Rap",
     "playback_count":6268472,"likes_count":90726,"reposts_count":262,"comment_count":522,
     "created_at":"2023-04-13T21:01:18Z"}
    """.utf8))
    let page = TrackPageModel(track: track, api: model.api)
    page.seedForPreview(comments: [
        sampleComment(1, "Кирилл Мельников", "легенда", 6955),
        sampleComment(2, "FAX UT", "огонь", 39650),
        sampleComment(3, "DJ 7up", "только мы вдвоем", 105993),
        sampleComment(4, "darinkas", "🔥", 148000),
        sampleComment(5, "wmelon", "пацы, кто фит??? пишите мне в комы под трэками", 96000),
    ])
    return TrackHero(track: track, model: model, page: page,
                     previewComment: page.comments.last)
        .padding(24)
        .environment(model.library)
        .frame(width: 1100, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.scOrange)
}
#endif
