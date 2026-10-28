import AppKit
import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.isAuthenticated {
                LibraryShell(model: model)
                    .frame(minWidth: 1040, maxWidth: .infinity,
                           minHeight: 620, maxHeight: .infinity)
            } else {
                // A definite size, not a minimum: with `.windowResizability(.contentSize)` this is
                // what the window becomes, and the welcome screen stops inheriting the shell's frame.
                WelcomeView(model: model)
                    .frame(width: 560, height: 640)
            }
        }
        .background(WindowCentering(isAuthenticated: model.isAuthenticated))
        .tint(.scOrange)
    }
}

// The content-sized window keeps its top-left corner as it shrinks to the welcome screen or grows to the shell.
private struct WindowCentering: NSViewRepresentable {
    let isAuthenticated: Bool

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // A launch into the shell keeps the frame the window was left with.
        if !isAuthenticated { center(probe) }
        return probe
    }

    func updateNSView(_ probe: NSView, context: Context) {
        guard context.coordinator.isAuthenticated != isAuthenticated else { return }
        context.coordinator.isAuthenticated = isAuthenticated
        center(probe)
    }

    func makeCoordinator() -> Coordinator { Coordinator(isAuthenticated: isAuthenticated) }

    private func center(_ probe: NSView) {
        // A turn later: the window takes its new content size first.
        DispatchQueue.main.async { probe.window?.center() }
    }

    final class Coordinator {
        var isAuthenticated: Bool
        init(isAuthenticated: Bool) { self.isAuthenticated = isAuthenticated }
    }
}

struct LibraryShell: View {
    let model: AppModel
    @State private var section: LibrarySection?
    /// Owned here so the player pill — which lives outside the stack — can push onto it.
    @State private var pageController: HistoryPageController?
    /// What the column shows right now — the page controller reports it, gesture or button alike.
    @State private var shown: AnyHashable = LibrarySection.home
    @State private var canGoBack = false
    @State private var canGoForward = false
    /// Pages whose hero has scrolled its own name out of sight, so the toolbar says it instead.
    @State private var collapsedTitles: Set<AnyHashable> = []
    @State private var showsCrashNotice = Diagnostics.previousRunEndedBadly
    @State private var detailFrame = DetailColumnFrame()
    @State private var room = PageRoom()
    @State private var showQueue = false
    @State private var viewer = ArtworkViewer()
    @State private var fullPlayer = FullPlayerPresenter()
    @State private var reloads = PageReloads()

    nonisolated static let shellSpace = "shell"

    /// Seeded here rather than corrected in a `.task`: landing on Home for one runloop still runs
    /// its three loaders, and they spawn unstructured Tasks that tearing the view down can't cancel.
    init(model: AppModel) {
        self.model = model
        let stored = UserDefaults.standard.string(forKey: LibrarySection.storageKey)
        _section = State(initialValue: stored.flatMap(LibrarySection.init(rawValue:)) ?? .home)
    }

    private func toggleFullPlayer(fullScreen: Bool) {
        fullPlayer.toggle(fullScreen: fullScreen) {
            AnyView(FullPlayerView(model: model) { pageController?.open($0) }
                .environment(model.library))
        }
    }

    private var pages: ShellPages {
        ShellPages(model: model, reloads: reloads, viewer: viewer, room: room, section: section ?? .home,
                   open: { pageController?.open($0) },
                   onTitleCollapse: { object, collapsed in
                       if collapsed { collapsedTitles.insert(object) } else { collapsedTitles.remove(object) }
                   })
    }

    /// A press is a step in the window's history, the section already shown included — that is how
    /// a pushed page is left, and a selection binding says nothing when it repeats.
    private func select(_ item: LibrarySection) {
        pageController?.openSection(item)
        section = item
    }

    var body: some View {
        // The column can only ever grow: the minimum is the default width, which also keeps the
        // collapse gesture from squeezing it away. No columnVisibility binding — driving one from
        // here made the split view re-lay itself out on every pass.
        NavigationSplitView {
            SidebarNav(section: $section, highlighted: shown as? LibrarySection, onSelect: select)
                .background { SidebarPin().frame(width: 0, height: 0) }
                .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    AccountRow(model: model, section: $section)
                    Link("Powered by SoundCloud", destination: URL(string: "https://soundcloud.com")!)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            }
            .task { model.library.loadMe() }
            .task { model.library.loadTrackStateIfNeeded() }
            .task { await model.restoreSession() }
            // After `toolbar(removing:)`, which swallows it: set before, the column kept AppKit's
            // own 140 minimum and no maximum at all, and the sidebar dragged out to any width.
            .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 270)
        } detail: {
            NavigationPages(root: section ?? .home,
                            page: { pages.page(for: $0) },
                            onShow: { object, shownSection, back, forward in
                                shown = object
                                // The sidebar follows the history: Back into another section lights that one.
                                if let shownSection = shownSection as? LibrarySection, section != shownSection {
                                    section = shownSection
                                }
                                canGoBack = back
                                canGoForward = forward
                                if object is LibrarySection { PageMemory.forget() } else { PageMemory.remember(object) }
                            },
                            controller: $pageController)
            // onGeometryChange rather than onChange inside a GeometryReader: writing state from
            // the latter re-runs layout in the same frame, which SwiftUI flags as updating multiple
            // times per frame. Horizontal only: mid-resize the titlebar is re-measured and the
            // column's top flickers 52 -> 34 -> 52 within a frame, which SwiftUI flags as cycling.
            .onGeometryChange(for: ColumnSpan.self) { proxy in
                let frame = proxy.frame(in: .named(Self.shellSpace))
                return ColumnSpan(minX: frame.minX, width: frame.width)
            } action: { span in
                detailFrame.span = span
                if room.detailMinX != span.minX { room.detailMinX = span.minX }
            }
        }
        // Attached to the split view, not to the detail's NavigationStack: inside the stack the
        // inspector shares a layer with the pushed page, which then covers it.
        .inspector(isPresented: $showQueue) {
            QueuePanel(player: model.player) { showQueue = false }
                // Full width from the slide's first frame: what the queue will take, known before it takes it.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if room.queueWidth != width { room.queueWidth = width }
                }
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .environment(\.navigator, Navigator { pageController?.open(AnyHashable($0)) })
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if room.shellWidth != width { room.shellWidth = width }
        }
        .coordinateSpace(.named(Self.shellSpace))
        .navigationTitle(ShellPages.title(of: shown, collapsed: collapsedTitles))
        // Apple Music's shape: the bar carries no fill of its own, the page runs under it and shows
        // through — so a page with nothing to say up there has no empty strip either.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The bar is AppKit's from here on, the one way the Back button animates in and out.
        .background(WindowToolbar(canGoBack: canGoBack, canGoForward: canGoForward,
                                  goBack: { pageController?.goBack() },
                                  goForward: { pageController?.goForward() }))
        .focusedSceneValue(\.shellActions, ShellActions(
            isQueueVisible: showQueue,
            toggleQueue: { showQueue.toggle() },
            find: {
                // Sections without a field send you to Search, which is where ⌘F is expected to land anyway.
                let target: LibrarySection = section == .likes ? .likes : .search
                // From a page opened inside the section the field is a step back, on its root.
                if shown != AnyHashable(target) { select(target) }
                model.requestFieldFocus(in: target)
            },
            openCurrentTrack: {
                if let track = model.player.currentTrack { pageController?.open(track) }
            },
            isFullPlayerOpen: fullPlayer.isOpen,
            toggleFullPlayer: { toggleFullPlayer(fullScreen: true) }))
        .focusedSceneValue(\.pageNavigation, PageNavigation(
            canGoBack: canGoBack, canGoForward: canGoForward,
            goBack: { pageController?.goBack() }, goForward: { pageController?.goForward() }))
        .refreshTriggers(model: model, shown: shown, reloads: reloads)

        .onChange(of: section) { _, new in
            if let new { UserDefaults.standard.set(new.rawValue, forKey: LibrarySection.storageKey) }
        }
        .onChange(of: showQueue) { _, open in
            withAnimation(.snappy) { room.isQueueOpen = open }
        }
        .restoresLastPage(api: model.api, shown: { shown }, controller: { pageController })
        .shellKeys(model: model, viewer: viewer, fullPlayer: fullPlayer, window: { pageController?.view.window })
        .modifier(ShellOverlays(model: model, column: detailFrame, fullPlayer: fullPlayer,
                                showQueue: $showQueue, showsCrashNotice: $showsCrashNotice,
                                open: { pageController?.open($0) },
                                expand: { toggleFullPlayer(fullScreen: false) }))
        .animation(.snappy, value: showQueue)
        .environment(viewer)
        .environment(room)
        .environment(model.library)
    }
}

#if DEBUG
#Preview {
    ContentView(model: AppModel())
}
#endif
