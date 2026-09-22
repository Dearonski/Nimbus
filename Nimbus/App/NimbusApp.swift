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
        WindowGroup {
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
            PlaybackCommands(player: model.player)
            RefreshCommands(model: model)
            CommandGroup(replacing: .help) {
                Button("Report an Issue…") { Diagnostics.reportIssue() }
            }
        }
    }
}

struct RefreshCommands: Commands {
    let model: AppModel
    @FocusedValue(\.pageNavigation) private var navigation

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Back") { navigation?.goBack() }
                .keyboardShortcut("[")
                .disabled(navigation?.canGoBack != true)
            Button("Forward") { navigation?.goForward() }
                .keyboardShortcut("]")
                .disabled(navigation?.canGoForward != true)
            Divider()
            Button("Refresh") { model.refreshRequest += 1 }
                .keyboardShortcut("r")
                .disabled(!model.isAuthenticated)
            Divider()
        }
    }
}

/// Transport in the menu bar, which is also what gives the shortcuts. Command-arrows rather than
/// bare arrows: the plain keys stay free for list navigation and a future drag-to-seek.
struct PlaybackCommands: Commands {
    let player: PlayerEngine

    var body: some Commands {
        CommandMenu("Playback") {
            // No Space shortcut here on purpose: a menu shortcut fires even while a text field has
            // focus, which would type-and-play instead of typing. The shell watches Space with an
            // event monitor that stands aside while a field reports `isTypingInField`.
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .disabled(player.currentTrack == nil)

            Button("Next") { Task { await player.next() } }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.canGoNext)

            Button("Previous") { Task { await player.previous() } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!player.canGoPrevious)

            Divider()

            Button(player.isShuffled ? "Shuffle: On" : "Shuffle: Off") { player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Repeat") { player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
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

extension FocusedValues {
    @Entry var pageNavigation: PageNavigation?
}
