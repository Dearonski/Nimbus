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
    @State private var model = AppModel()

    init() {
        Diagnostics.begin()
        ScrollActivity.start()
        // Counts half of the real cost: SwiftUI keeps an IOSurface copy of every image it has shown (measured 19.09.2026).
        ImageCache.shared.costLimit = 48 * 1024 * 1024
        // A 3000 px original (~36 MB) still has to fit: the lightbox copies it out of this cache.
        ImageCache.shared.entryCostLimit = 0.8
    }

    var body: some Scene {
        // One window, as in Music: a second shell doubled the key monitors and refresh triggers.
        Window("Nimbus", id: "main") {
            ContentView(model: model)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in
                    Diagnostics.end()
                }
        }
        // The welcome screen states a definite size and the shell states a minimum, so letting the
        // content drive resizability is what makes the window shrink for one and grow for the other.
        .windowResizability(.contentSize)
        .defaultSize(width: 1200, height: 780)
        .defaultPosition(.center)
        .commands {
            AppCommands(model: model)
            ViewCommands(model: model)
            ControlsCommands(player: model.player)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @FocusedValue(\.shellActions) private var shell
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
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
            Button("Nimbus") { openWindow(id: "main") }
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
    @FocusedValue(\.pageNavigation) private var navigation
    @FocusedValue(\.shellActions) private var shell

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Back") { navigation?.goBack() }
                .keyboardShortcut("[")
                .disabled(navigation?.canGoBack != true)
            Button("Forward") { navigation?.goForward() }
                .keyboardShortcut("]")
                .disabled(navigation?.canGoForward != true)
            Divider()
            // Music's shortcut for its own Playing Next.
            Button(shell?.isQueueVisible == true ? "Hide Queue" : "Show Queue") { shell?.toggleQueue() }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(shell == nil)
            Button("Refresh") { model.refreshRequest += 1 }
                .keyboardShortcut("r")
                .disabled(!model.isAuthenticated)
            Divider()
        }
    }
}

// Command-arrows rather than bare arrows: the plain keys stay free for lists.
struct ControlsCommands: Commands {
    let player: PlayerEngine
    @FocusedValue(\.shellActions) private var shell

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
        }
    }
}

/// The front window's history, for the menu: Back and Forward act on the window they are chosen in.
struct PageNavigation {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void
}

struct ShellActions {
    let isQueueVisible: Bool
    let toggleQueue: () -> Void
    /// ⌘F: the filter on Likes, Search anywhere else.
    let find: () -> Void
    let openCurrentTrack: () -> Void
}

extension FocusedValues {
    @Entry var pageNavigation: PageNavigation?
    @Entry var shellActions: ShellActions?
}
