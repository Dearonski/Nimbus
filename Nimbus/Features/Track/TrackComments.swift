import AppKit
import SwiftUI

/// The comment list under a track: who said what, at which second, and the replies underneath.
struct TrackComments: View {
    let page: TrackPageModel
    let model: AppModel

    private var total: Int { page.track.commentCount ?? page.comments.count }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            header

            let triggers = page.comments.pagingTriggerIDs
            ForEach(page.comments) { comment in
                CommentRow(comment: comment, page: page, model: model)
                    .paginates(triggers.contains(comment.id)) { await page.loadMoreComments() }
            }

            FeedFooter(pager: page.commentPages)

            if let error = page.commentPages.firstPageError, !page.isLoadingComments {
                LoadFailure(title: "Couldn't load comments", message: error) {
                    Task { await page.loadMoreComments() }
                }
                .padding(.vertical, 10)
            } else if page.comments.isEmpty && page.commentPages.hasLoaded {
                Text("No comments yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(total) comment\(total == 1 ? "" : "s")".uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Menu {
                Picker("", selection: Binding(get: { page.sort }, set: { page.sort = $0 })) {
                    Text("Newest").tag(SCCommentSort.newest)
                    Text("Oldest").tag(SCCommentSort.oldest)
                    Text("By position").tag(SCCommentSort.timestamp)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Text(sortLabel)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .glassButton()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private var sortLabel: String {
        switch page.sort {
        case .oldest: "Oldest"
        case .timestamp: "By position"
        default: "Newest"
        }
    }
}

private struct CommentRow: View {
    let comment: SCComment
    let page: TrackPageModel
    let model: AppModel
    var isReply = false

    @State private var hovering = false

    private var state: TrackPageModel.CommentState { page.state(for: comment) }
    private var isMine: Bool { comment.user.id == model.library.meUser?.id }
    private var replies: [SCComment] { page.replies[comment.urn] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                NavButton(value: comment.user) {
                    Artwork(comment.user, size: .thumb)
                        .frame(width: isReply ? 26 : 32, height: isReply ? 26 : 32)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    byline
                    Text(comment.body)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    footer
                }

                Spacer(minLength: 8)
                likeButton
            }
            .padding(.vertical, 12)

            if !replies.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(replies) { reply in
                        CommentRow(comment: reply, page: page, model: model, isReply: true)
                    }
                }
                .padding(.leading, 44)
            }
        }
        .overlay(alignment: .bottom) {
            if !isReply {
                Rectangle().fill(.primary.opacity(0.05)).frame(height: 1)
            }
        }
        .onHover { hovering = $0 }
        .task { await page.loadReplies(for: comment) }
    }

    private var byline: some View {
        HStack(spacing: 5) {
            NavButton(value: comment.user) {
                Text(comment.user.username)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(.plain)

            Text("at")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button {
                model.player.seek(to: Double(comment.trackTime) / 1000)
            } label: {
                Text(timeString(Double(comment.trackTime) / 1000))
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            if let age = comment.ageLabel {
                Text("· \(age)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 14) {
            Button("Reply") { page.beginReply(to: comment) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            Menu {
                if isMine {
                    Button("Delete", systemImage: "trash", role: .destructive) { page.delete(comment) }
                } else {
                    Button("Report comment", systemImage: "flag") { page.report(comment) }
                }
                Button("Copy text", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(comment.body, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            // Only on the row under the pointer: a column of dots down every comment is noise.
            .opacity(hovering ? 1 : 0)

            if page.reported.contains(comment.urn) {
                Text("Reported").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11.5))
        .padding(.top, 4)
    }

    private var likeButton: some View {
        Button { page.toggleLike(comment) } label: {
            VStack(spacing: 2) {
                Image(systemName: state.liked ? "heart.fill" : "heart")
                    .font(.system(size: 13))
                    .foregroundStyle(state.liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                if state.likes > 0 {
                    Text("\(state.likes)")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
func sampleComment(_ id: Int, _ name: String, _ body: String, _ at: Int,
                   likes: Int = 0, replies: Int = 0) -> SCComment {
    let json = """
    {"urn":"soundcloud:comments:\(id)","body":"\(body)","createdAt":"2026-09-01T20:25:00Z",
     "trackTime":\(at),"replies":{"total":\(replies)},
     "reactions":{"userReaction":null,
       "reactionCounts":[{"reactionTypeValueUrn":"sc:interactiontypevalue:like","count":\(likes)}]},
     "user":{"urn":"soundcloud:users:\(id * 7)","username":"\(name)","avatarUrl":null,
       "verified":false,"permalinkUrl":"x","followersCount":120,"tracksCount":4}}
    """
    return try! JSONDecoder().decode(SCComment.self, from: Data(json.utf8))
}

#Preview("Comments") {
    let model = AppModel()
    let track = try! JSONDecoder().decode(SCTrack.self, from: Data("""
    {"id":1,"title":"6AM","duration":183224,"permalink_url":"x","artwork_url":null,
     "user":{"id":9,"username":"OG Buda"},"media":{"transcodings":[]},"track_authorization":"",
     "comment_count":522}
    """.utf8))
    let page = TrackPageModel(track: track, api: model.api)
    page.seedForPreview(comments: [
        sampleComment(1, "Кирилл Мельников", "легенда", 6955, likes: 3),
        sampleComment(2, "FAX UT", "лучший трек года, серьёзно", 19650),
        sampleComment(3, "DJ 7up", "только мы вдвоем", 165993, likes: 12, replies: 2),
        sampleComment(4, "darinkas", "🥺🔥", 31000),
    ])
    return ScrollView {
        TrackComments(page: page, model: model)
            .padding(24)
    }
    .environment(model.library)
    .frame(width: 760, height: 620)
    .tint(.scOrange)
}
#endif
