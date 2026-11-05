//
//  NimbusApp.swift
//  Nimbus
//
//  Created by Кирилл on 09.07.2026.
//

import Nuke
import SwiftUI

@main
struct NimbusApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var updates = Updates()

    init() {
        Diagnostics.begin()
        ScrollActivity.start()
        // Counts half of the real cost: SwiftUI keeps an IOSurface copy of every image it has shown (measured 19.09.2026).
        ImageCache.shared.costLimit = 48 * 1024 * 1024
        // A 3000 px original (~36 MB) still has to fit: the lightbox copies it out of this cache.
        ImageCache.shared.entryCostLimit = 0.8
    }

    var body: some Scene {
        // The main window is AppKit's (`MainWindowController`); a scene is still needed to carry the menus.
        Settings { EmptyView() }
            .commands {
                AppCommands(model: delegate.model, updates: updates, showWindow: delegate.showMainWindow)
                ViewCommands(model: delegate.model)
                ControlsCommands(model: delegate.model)
            }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    let updates: Updates
    let showWindow: () -> Void

    private var shell: ShellState? { model.shell }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.check() }
                .disabled(!updates.canCheck)
        }
        // Where Music keeps its account; no Settings item — there is nothing to set yet.
        CommandGroup(replacing: .appSettings) {
            Button("Sign Out…", action: confirmSignOut)
                .disabled(!model.isAuthenticated)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { shell?.find() }
                .keyboardShortcut("f")
                .disabled(shell == nil)
        }
        // The one way back to a closed window from the menus; the scene did not list itself.
        CommandGroup(before: .windowList) {
            Button("Nimbus", action: showWindow)
                .keyboardShortcut("0")
        }
        CommandGroup(replacing: .help) {
            Button("Report an Issue…") { Diagnostics.reportIssue() }
            Divider()
            Button("Nimbus on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Dearonski/Nimbus")!)
            }
        }
    }

    private func confirmSignOut() {
        let alert = NSAlert()
        alert.messageText = "Sign out of SoundCloud?"
        alert.informativeText = "Your queue and history stay on this Mac. Signing in again brings everything back."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.signOut()
    }
}

struct ViewCommands: Commands {
    let model: AppModel

    private var shell: ShellState? { model.shell }

    private var likes: LikesControls { model.likesControls }
    private var search: SearchControls { model.searchControls }
    private var onLikes: Bool { shell?.shown == AnyHashable(LibrarySection.likes) }
    private var onSearch: Bool { shell?.shown == AnyHashable(LibrarySection.search) }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            // The toolbar's controls again: a toolbar can be hidden, the menu bar cannot.
            Picker("Layout", selection: Binding(get: { likes.layout }, set: { likes.layout = $0 })) {
                ForEach(LibraryLayout.allCases) { Text("as \($0.title)").tag($0) }
            }
            .pickerStyle(.inline)
            .disabled(!onLikes)
            if onSearch {
                Picker("Show", selection: Binding(get: { search.scope }, set: { search.scope = $0 })) {
                    ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(search.isBlank)
                Picker("Sort By", selection: Binding(get: { search.sort }, set: { search.sort = $0 })) {
                    ForEach(search.sortOptions) { Text($0.rawValue).tag($0) }
                }
                .disabled(search.isBlank)
            } else {
                Picker("Sort By", selection: Binding(get: { likes.sort }, set: { likes.sort = $0 })) {
                    ForEach(LikesSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!onLikes)
            }
            Divider()
            Button("Back") { shell?.goBack() }
                .keyboardShortcut("[")
                .disabled(shell?.canGoBack != true)
            Button("Forward") { shell?.goForward() }
                .keyboardShortcut("]")
                .disabled(shell?.canGoForward != true)
            Divider()
            // Music's shortcut for its own Playing Next.
            Button(shell?.isQueueVisible == true ? "Hide Queue" : "Show Queue") { shell?.toggleQueue() }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(shell == nil)
            Button("Refresh") { shell?.refreshShownPage() }
                .keyboardShortcut("r")
                .disabled(!model.isAuthenticated)
            // Music's shortcut for its own; Control-Command-F is the window's Enter Full Screen.
            Button(shell?.fullPlayer.isOpen == true ? "Exit Full Screen Player" : "Full Screen Player") {
                shell?.toggleFullPlayer(fullScreen: true)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(shell == nil || model.player.currentTrack == nil)
            Divider()
        }
    }
}

// Command-arrows rather than bare arrows: the plain keys stay free for lists.
struct ControlsCommands: Commands {
    let model: AppModel

    private var player: PlayerEngine { model.player }
    private var shell: ShellState? { model.shell }

    var body: some Commands {
        CommandMenu("Controls") {
            // No Space shortcut here on purpose: a menu shortcut fires even while a text field has
            // focus, which would type-and-play instead of typing. The shell watches Space with an
            // event monitor that stands aside while a field reports `isTypingInField`.
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .disabled(player.currentTrack == nil)

            Divider()

            Button("Next") { Task { await player.next() } }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.canGoNext)
            Button("Previous") { Task { await player.previous() } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!player.canGoPrevious)
            Button("Go to Current Track") { shell?.openCurrentTrack() }
                .keyboardShortcut("l")
                .disabled(player.currentTrack == nil || shell == nil)

            Divider()

            Button("Increase Volume") { player.nudgeVolume(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { player.nudgeVolume(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            // State as a checkmark, the way a Mac menu shows it, not written into the title.
            Toggle("Shuffle", isOn: Binding(get: { player.isShuffled }, set: { _ in player.toggleShuffle() }))
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.setRepeat($0) })) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }
            Toggle("Autoplay Related", isOn: Binding(
                get: { player.autoplayRelated },
                set: { player.autoplayRelated = $0 }))

            Divider()

            SpeedMenu(player: player)
        }
    }
}
