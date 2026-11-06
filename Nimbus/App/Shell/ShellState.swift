import AppKit
import SwiftUI

// The menus read this through `AppModel.shell`: with a single window there is no focus to look up.
@MainActor
@Observable
final class ShellState {
    var section: LibrarySection? {
        didSet {
            guard section != oldValue else { return }
            if let section { UserDefaults.standard.set(section.rawValue, forKey: LibrarySection.storageKey) }
            // The sidebar following the history lands here too; the controller tells that from a choice.
            pages?.follow(root: section ?? .home)
        }
    }
    private(set) var shown: AnyHashable = LibrarySection.home
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var collapsedTitles: Set<AnyHashable> = []
    private(set) var isQueueVisible = false
    private(set) var isSidebarVisible = true

    let viewer = ArtworkViewer()
    let fullPlayer = FullPlayerPresenter()
    let reloads = PageReloads()
    let room = PageRoom()

    @ObservationIgnored weak var pages: HistoryPageController?
    @ObservationIgnored var onQueueVisibility: (Bool) -> Void = { _ in }
    @ObservationIgnored var revealSidebar: (Bool, @escaping @MainActor () -> Void) -> Void = { _, then in then() }
    @ObservationIgnored var focusToolbarField: (LibrarySection) -> Void = { _ in }
    @ObservationIgnored weak var searchField: SidebarSearchField?
    let model: AppModel

    init(model: AppModel) {
        self.model = model
        let stored = Preference.opensHome ? nil : UserDefaults.standard.string(forKey: LibrarySection.storageKey)
        section = stored.flatMap(LibrarySection.init(rawValue:)) ?? .home
    }

    var title: String { ShellPages.title(of: shown, collapsed: collapsedTitles) }

    // MARK: - History

    // A press is a step in the window's history, the section already shown included — that is how a
    // pushed page is left, and a selection binding says nothing when it repeats.
    func select(_ item: LibrarySection) {
        // Sidebar rows take no focus when clicked, so typing would have stayed in the search field.
        if item != .search { ShellSearchField.endEditing() }
        pages?.openSection(item)
        section = item
    }

    func open(_ object: AnyHashable) { pages?.open(object) }
    func goBack() { pages?.goBack() }
    func goForward() { pages?.goForward() }

    func showed(_ object: AnyHashable, in shownSection: AnyHashable, back: Bool, forward: Bool) {
        shown = object
        // The sidebar follows the history: Back into another section lights that one.
        if let shownSection = shownSection as? LibrarySection, section != shownSection { section = shownSection }
        canGoBack = back
        canGoForward = forward
        if object is LibrarySection { PageMemory.forget() } else { PageMemory.remember(object) }
    }

    func titleCollapsed(_ collapsed: Bool, on object: AnyHashable) {
        if collapsed { collapsedTitles.insert(object) } else { collapsedTitles.remove(object) }
    }

    // MARK: - Actions

    func setQueueVisible(_ visible: Bool) {
        guard visible != isQueueVisible else { return }
        isQueueVisible = visible
        onQueueVisibility(visible)
        withAnimation(.snappy) { room.isQueueOpen = visible }
    }

    func toggleQueue() { setQueueVisible(!isQueueVisible) }

    func toggleSidebar() { revealSidebar(!isSidebarVisible) {} }

    // Collapsed by the toolbar button, by a drag or by the window narrowing; the menu title follows all three.
    func sidebarCollapsed(_ collapsed: Bool) {
        if isSidebarVisible == collapsed { isSidebarVisible = !collapsed }
    }

    // Likes filters itself; anywhere else ⌘F means the catalogue, as it does in Music.
    func find() {
        guard section == .likes else {
            showSearch()
            // The field lives in the sidebar; a hidden one can't take focus.
            revealSidebar(true) { [weak self] in self?.searchField?.focus() }
            return
        }
        // From a page opened inside the section the field is a step back, on its root.
        if shown != AnyHashable(LibrarySection.likes) { select(.likes) }
        focusToolbarField(.likes)
    }

    func showSearch() {
        if shown != AnyHashable(LibrarySection.search) { select(.search) }
    }

    func openCurrentTrack() {
        if let track = model.player.currentTrack { open(track) }
    }

    func toggleFullPlayer(fullScreen: Bool) {
        let model = model
        fullPlayer.toggle(fullScreen: fullScreen) { [weak self] in
            AnyView(FullPlayerView(model: model) { self?.open($0) }.environment(model.library).tint(.scOrange))
        }
    }
}
