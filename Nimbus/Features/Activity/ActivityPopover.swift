import SwiftUI

struct ActivityPopover: View {
    let store: ActivityStore

    // Taken as it opens and before everything is marked seen, so this look can still show what was new.
    @State private var newSince: Date?

    private func isNew(_ activity: SCActivity) -> Bool {
        guard let newSince, let date = activity.date else { return false }
        return date > newSince
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            content
        }
        .frame(width: 400)
        .onAppear {
            newSince = store.seenUntil
            store.markSeen()
            store.loadIfNeeded()
        }
        .onChange(of: store.items.first?.id) { store.markSeen() }
    }

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty {
            Group {
                if store.list.isLoading {
                    ProgressView().controlSize(.small)
                } else if let error = store.list.error {
                    VStack(spacing: 8) {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") { store.loadIfNeeded(force: true) }
                    }
                } else {
                    Text("Follows, likes, reposts and comments on your tracks appear here.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(.horizontal, 24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.items) { ActivityRow(activity: $0, isNew: isNew($0)) }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ActivityRow: View {
    let activity: SCActivity
    let isNew: Bool

    static let inset: CGFloat = 10

    @Environment(\.navigator) private var navigator
    @Environment(LibraryStore.self) private var library: LibraryStore?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(.tint)
                .frame(width: 6, height: 6)
                .opacity(isNew ? 1 : 0)

            Artwork(activity.user, size: .thumb)
                .frame(width: 40, height: 40)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                headline
                    .lineLimit(2)
                if let body = activity.comment?.body, !body.isEmpty {
                    Text("“\(body)”")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let age = activity.ageLabel {
                    Text(age)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { navigator.open(activity.target) }
        .onScrollSafeHover { hovering = $0 }
    }

    private var headline: Text {
        let name = Text(activity.user.username).fontWeight(.semibold)
        let line = if let title = activity.subjectTitle {
            Text("\(name) \(activity.action) \(Text(title).fontWeight(.semibold))")
        } else {
            Text("\(name) \(activity.action)")
        }
        return line.font(.system(size: 13))
    }

    @ViewBuilder
    private var trailing: some View {
        if activity.kind == .follow, let library {
            let following = library.isFollowing(activity.user)
            Button(following ? "Following" : "Follow Back") { library.toggleFollow(activity.user) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(following ? nil : .scOrange)
        } else if let track = activity.subjectTrack {
            cover(Artwork(track, size: .thumb))
        } else if let playlist = activity.playlist {
            cover(Artwork(playlist, size: .thumb))
        }
    }

    private func cover(_ artwork: Artwork) -> some View {
        artwork
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

#if DEBUG
#Preview("Activity rows") {
    let json = """
    [{"uuid":"a","type":"affiliation","created_at":"2026-11-04T14:06:24Z",
      "user":{"id":1,"username":"Биг Бодя"}},
     {"uuid":"b","type":"track-like","created_at":"2026-11-05T10:00:00Z",
      "user":{"id":2,"username":"дертитрабл"},
      "track":{"id":10,"title":"prop hunt [prod. ptrckparker]","duration":120000,"permalink_url":"x",
               "artwork_url":null,"user":{"id":3,"username":"ONDA ANDAR"},"media":{"transcodings":[]},
               "track_authorization":""}},
     {"uuid":"c","type":"comment","created_at":"2026-11-06T09:00:00Z",
      "user":{"id":4,"username":"wmelon"},
      "comment":{"id":5,"body":"пацы, кто фит??? пишите мне в комы под трэками","created_at":"2026-11-06T09:00:00Z",
                 "track":{"id":11,"title":"sleep mode [prod. cry 4 me]","duration":120000,"permalink_url":"x",
                          "artwork_url":null,"user":{"id":3,"username":"ONDA ANDAR"},"media":{"transcodings":[]},
                          "track_authorization":""}}}]
    """
    let items = try! JSONDecoder().decode([SCActivity].self, from: Data(json.utf8))
    return VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, activity in
            ActivityRow(activity: activity, isNew: index == 2)
        }
    }
    .padding(24)
    .frame(width: 400)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}
#endif
