import SwiftUI

/// Mirrors SoundCloud's own navigation: discovery and the social feed are separate destinations,
/// and the library splits the things `/me/library/all` already distinguishes.
enum LibrarySection: String, CaseIterable, Identifiable {
    case search = "Search"
    case home = "Home"
    case feed = "Feed"
    case likes = "Likes"
    case playlists = "Playlists"
    case albums = "Albums"
    case stations = "Stations"
    case following = "Following"
    case history = "History"
    case profile = "Profile"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house"
        case .feed: "newspaper"
        case .likes: "heart"
        case .playlists: "music.note.list"
        case .albums: "square.stack"
        case .stations: "dot.radiowaves.left.and.right"
        case .following: "person.2"
        case .history: "clock"
        case .profile: "person.crop.circle"
        }
    }

    static var browseCases: [LibrarySection] { [.search, .home, .feed] }
    static var libraryCases: [LibrarySection] { [.likes, .playlists, .albums, .stations, .following, .history] }

    static let storageKey = "librarySection"
}

/// A plain stack rather than a List: `.listStyle(.sidebar)` layers its own horizontal insets on top
/// of the row's, so the highlight never lines up with the column edges. Nine fixed destinations
/// need none of what List provides.
struct SidebarNav: View {
    @Binding var section: LibrarySection?
    var onSelect: (LibrarySection) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(LibrarySection.browseCases) { item in
                    SidebarRow(item: item, selection: $section, onSelect: onSelect)
                }

                Text("Library")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 14)
                    .padding(.bottom, 2)

                ForEach(LibrarySection.libraryCases) { item in
                    SidebarRow(item: item, selection: $section, onSelect: onSelect)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
        }
        .scrollContentBackground(.hidden)
    }
}

/// Rows draw their own selection: List's built-in highlight paints with the system accent colour
/// (blue by default), which no tint can override.
struct SidebarRow: View {
    let item: LibrarySection
    @Binding var selection: LibrarySection?
    var onSelect: (LibrarySection) -> Void = { _ in }

    @State private var hovering = false

    private var isActive: Bool { selection == item }
    private var tint: AnyShapeStyle { isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary) }

    var body: some View {
        // Hand-built rather than a Label: Music sets the icon 18pt in from the pill edge and 10pt
        // clear of the title, and Label exposes neither gap. The fixed icon box also keeps titles
        // aligned, since the symbols differ in width.
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(item.rawValue)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .background {
                // Music tints only the label and keeps the pill itself neutral grey; an accent-filled
                // row reads as a button rather than a selection.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.075 : (hovering ? 0.04 : 0)))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Told first: the shell reads a press of the section already shown off the old selection.
                onSelect(item)
                selection = item
            }
            .onHover { hovering = $0 }
    }
}

struct AccountRow: View {
    let model: AppModel
    @Binding var section: LibrarySection?

    private var me: SCUser? { model.library.meUser }

    var body: some View {
        HStack(spacing: 8) {
            Artwork(me, size: .thumb, placeholderOpacity: 0.2)
                .frame(width: 26, height: 26)
                .clipShape(Circle())

            Text(me?.username ?? "Account")
                .font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(.primary)

            Spacer()

            Menu {
                Button { section = .profile } label: {
                    Label("My Profile", systemImage: "person.crop.circle")
                }
                Divider()
                Button(role: .destructive) { model.signOut() } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
