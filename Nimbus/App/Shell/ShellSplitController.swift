import AppKit
import SwiftUI

// AppKit all the way down to the columns' content: a SwiftUI container over AppKit views relaid itself out
// and measured them through Auto Layout on every update anywhere beneath it.
@MainActor
final class ShellSplitController: NSSplitViewController {
    let pages = HistoryPageController()

    private let model: AppModel
    private let shell: ShellState
    private let hits = OverlayHits()
    private var sidebar: NSSplitViewItem?
    private var inspector: NSSplitViewItem?
    private var detail: NSSplitViewItem?
    private var sidebarObservation: NSKeyValueObservation?
    private var resizeObserver: (any NSObjectProtocol)?
    private var queueSliding = false

    init(model: AppModel, shell: ShellState) {
        self.model = model
        self.shell = shell
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "nimbus.shell"

        let sidebarContent = host(SidebarColumn(model: model, shell: shell))
        // App Store's width; a width the window was left with still wins.
        sidebarContent.view.frame.size.width = 220
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarContent)
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 270
        addSplitViewItem(sidebar)
        self.sidebar = sidebar

        let detail = NSSplitViewItem(viewController: DetailController(
            pages: pages, overlay: ShellOverlay(model: model, shell: shell, hits: hits), hits: hits))
        // The narrowest a page is laid out for, the queue open in a minimum window; below it the sidebar folds away.
        detail.minimumThickness = 580
        addSplitViewItem(detail)
        self.detail = detail

        let queue = host(QueuePanel(player: model.player) { [weak shell] in shell?.setQueueVisible(false) })
        queue.view.frame.size.width = shell.room.queueWidth
        let inspector = NSSplitViewItem(inspectorWithViewController: queue)
        inspector.minimumThickness = 260
        inspector.maximumThickness = 460
        inspector.isCollapsed = true
        addSplitViewItem(inspector)
        self.inspector = inspector

        shell.pages = pages
        pages.page = { [model, shell] in ShellPages(model: model, shell: shell).page(for: $0) }
        pages.onShow = { [weak shell] object, section, back, forward in
            shell?.showed(object, in: section, back: back, forward: forward)
        }
        pages.follow(root: shell.section ?? .home)
        shell.onQueueVisibility = { [weak self] visible in self?.slideQueue(open: visible) }
        shell.revealSidebar = { [weak self] visible, then in self?.slideSidebar(open: visible, then: then) }
        sidebarObservation = sidebar.observe(\.isCollapsed, options: [.initial, .new]) { [weak shell] item, _ in
            let collapsed = item.isCollapsed
            MainActor.assumeIsolated { shell?.sidebarCollapsed(collapsed) }
        }

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.measureRoom() }
        }
    }

    isolated deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    func tearDown() {
        pages.tearDown()
        shell.pages = nil
    }

    // Written only on change: every reader of the room reshapes its page when it moves.
    private func measureRoom() {
        let room = shell.room
        let width = splitView.bounds.width
        if room.shellWidth != width { room.shellWidth = width }
        if let column = detail?.viewController.view {
            let minX = column.convert(column.bounds, to: splitView).minX
            if room.detailMinX != minX { room.detailMinX = minX }
        }
        // Only a settled queue's width counts: pages decide their shape on where it lands, not mid-slide.
        if let inspector, !inspector.isCollapsed, !queueSliding {
            let queueWidth = inspector.viewController.view.frame.width
            if queueWidth > 0, room.queueWidth != queueWidth { room.queueWidth = queueWidth }
        }
    }

    private func slideQueue(open: Bool) {
        guard let inspector else { return }
        queueSliding = true
        NSAnimationContext.runAnimationGroup { _ in
            inspector.animator().isCollapsed = !open
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.queueSliding = false
                self?.measureRoom()
            }
        }
    }

    private func slideSidebar(open: Bool, then: @escaping @MainActor () -> Void) {
        guard let sidebar, sidebar.isCollapsed == open else { return then() }
        NSAnimationContext.runAnimationGroup { _ in
            sidebar.animator().isCollapsed = !open
        } completionHandler: {
            MainActor.assumeIsolated { then() }
        }
    }

    // What the shell's root used to hand down to everything under it; each column is its own root now.
    private func host(_ content: some View) -> NSHostingController<some View> {
        let shell = shell
        let controller = NSHostingController(rootView: content
            .environment(\.navigator, Navigator { [weak shell] in shell?.open(AnyHashable($0)) })
            .environment(shell.viewer)
            .environment(shell.room)
            .environment(model.library)
            .tint(.scOrange))
        // The split view owns the columns' sizes; measuring the content for constraints only re-asks it on every pass.
        controller.sizingOptions = []
        return controller
    }
}

// The page history with the pill and banners floating over it, as siblings: nothing SwiftUI sits above the pages.
@MainActor
private final class DetailController: NSViewController {
    private let pages: HistoryPageController
    private let overlay: OverlayHostingView<ShellOverlay>

    init(pages: HistoryPageController, overlay content: ShellOverlay, hits: OverlayHits) {
        self.pages = pages
        overlay = OverlayHostingView(rootView: content)
        overlay.sizingOptions = []
        overlay.hits = hits
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        addChild(pages)
        for child in [pages.view, overlay] {
            child.frame = view.bounds
            child.autoresizingMask = [.width, .height]
            view.addSubview(child)
        }
    }
}
