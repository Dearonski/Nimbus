import AppKit
import SwiftUI

// The one window, as in Music: the welcome screen until there is a session, then the shell.
@MainActor
final class MainWindowController: NSWindowController {
    private let model: AppModel
    private let toolbar = ShellToolbar()

    private struct Shell {
        let state: ShellState
        let split: ShellSplitController
        let keys: ShellKeys
        let triggers: RefreshTriggers
    }

    private var shell: Shell?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Nimbus"
        window.toolbarStyle = .unified
        super.init(window: window)
        toolbar.register(LikesToolbar(controls: model.likesControls), for: .likes)
        toolbar.register(SearchToolbar(controls: model.searchControls), for: .search)
        present()
        followSession()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private func followSession() {
        withObservationTracking { _ = model.isAuthenticated } onChange: { [weak self] in
            Task { @MainActor in
                self?.present()
                self?.followSession()
            }
        }
    }

    private func present() {
        guard let window else { return }
        if model.isAuthenticated {
            guard shell == nil else { return }
            showShell(in: window)
        } else {
            showWelcome(in: window)
        }
    }

    // MARK: - Welcome

    private func showWelcome(in window: NSWindow) {
        if let shell {
            shell.split.tearDown()
            model.shell = nil
            self.shell = nil
        }
        // The toolbar is the window's, not the view's: left behind, the welcome screen kept Back and Forward.
        toolbar.detach()
        window.setFrameAutosaveName("")
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 560, height: 640)
        window.styleMask.remove(.resizable)
        window.title = "Nimbus"
        window.contentViewController = NSHostingController(rootView: WelcomeView(model: model)
            .frame(width: 560, height: 640)
            .tint(.scOrange))
        window.setContentSize(NSSize(width: 560, height: 640))
        window.center()
    }

    // MARK: - Shell

    private func showShell(in window: NSWindow) {
        let state = ShellState(model: model)
        let split = ShellSplitController(model: model, shell: state)
        let keys = ShellKeys(model: model, viewer: state.viewer, fullPlayer: state.fullPlayer) { [weak window] in
            window
        }
        let shell = Shell(state: state, split: split, keys: keys, triggers: RefreshTriggers(model: model))
        self.shell = shell
        model.shell = state
        state.focusToolbarField = { [weak toolbar] in toolbar?.focusField(on: $0) }

        window.styleMask.insert(.resizable)
        window.titlebarAppearsTransparent = false
        window.contentViewController = split
        window.contentMinSize = NSSize(width: 1040, height: 620)
        toolbar.attach(to: window)
        window.setContentSize(NSSize(width: 1200, height: 780))
        window.center()
        // Puts back the frame the window was left with, if there is one.
        window.setFrameAutosaveName("main")
        follow(state)
        restoreLastPage(state)
    }

    // The title and the toolbar's pair follow the history.
    private func follow(_ state: ShellState) {
        withObservationTracking {
            toolbar.show(page: state.shown)
            window?.title = state.title
            toolbar.update(canGoBack: state.canGoBack, canGoForward: state.canGoForward,
                           goBack: { [weak state] in state?.goBack() },
                           goForward: { [weak state] in state?.goForward() })
        } onChange: { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state, self.shell?.state === state else { return }
                self.follow(state)
            }
        }
    }

    // Opens the page the window was left on, unless the user has gone somewhere else meanwhile.
    private func restoreLastPage(_ state: ShellState) {
        guard let memory = PageMemory.stored() else { return }
        let api = model.api
        Task { [weak state] in
            let before = state?.shown
            guard let page = await memory.resolve(api: api), let state, state.shown == before else { return }
            state.open(page)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var main: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.end()
    }

    func showMainWindow() {
        let main = main ?? MainWindowController(model: model)
        self.main = main
        main.showWindow(nil)
    }
}
