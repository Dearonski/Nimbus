//
//  NimbusApp.swift
//  Nimbus
//
//  Created by Кирилл on 09.07.2026.
//

import SwiftUI

@main
struct NimbusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        // The welcome screen states a definite size and the shell states a minimum, so letting the
        // content drive resizability is what makes the window shrink for one and grow for the other.
        .windowResizability(.contentSize)
        .defaultSize(width: 1200, height: 780)
        .defaultPosition(.center)
        .commands { PlaybackCommands(player: model.player) }
    }
}

/// Transport in the menu bar, which is also what gives the shortcuts. Command-arrows rather than
/// bare arrows: the plain keys stay free for list navigation and a future drag-to-seek.
struct PlaybackCommands: Commands {
    let player: PlayerEngine

    var body: some Commands {
        CommandMenu("Playback") {
            // No Space shortcut here on purpose: a menu shortcut fires even while a text field has
            // focus, which would type-and-play instead of typing. The shell handles Space through
            // onKeyPress, which the focused field swallows first.
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
