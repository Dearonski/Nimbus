import SwiftUI

/// The speed, as the corner of the pill's display shows it. At 1× it stays out of sight until the
/// pointer is over the pill, so the control is there to find without weighing on a pill that
/// almost always plays at normal speed; off 1× it stays lit, so a changed speed is never a mystery.
struct SpeedBadge: View {
    let speed: Float
    let keepsPitch: Bool
    /// The pointer is somewhere over the pill.
    let isRevealed: Bool
    let action: () -> Void

    @State private var hovering = false

    private var isChanged: Bool { speed != 1 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if isChanged && !keepsPitch {
                    Image(systemName: "record.circle").font(.system(size: 9.5, weight: .semibold))
                }
                Text(speedLabel(speed)).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(isChanged ? AnyShapeStyle(.tint)
                             : AnyShapeStyle(Color(nsColor: hovering ? .secondaryLabelColor : .tertiaryLabelColor)))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(isChanged ? AnyShapeStyle(.tint.opacity(hovering ? 0.24 : 0.16))
                                         : AnyShapeStyle(.primary.opacity(hovering ? 0.1 : 0.05)))
            }
            .overlay {
                if !isChanged { Capsule().strokeBorder(.primary.opacity(hovering ? 0.14 : 0.08)) }
            }
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Playback Speed")
        .onHover { hovering = $0 }
        .opacity(isChanged || isRevealed ? 1 : 0)
        .allowsHitTesting(isChanged || isRevealed)
        .animation(.easeOut(duration: 0.15), value: isRevealed)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// What the badge opens: presets for the usual stops, a slider for the rest, and the pitch mode.
struct SpeedPanel: View {
    let speed: Float
    let keepsPitch: Bool
    let onSpeed: (Float) -> Void
    let onKeepsPitch: (Bool) -> Void

    private static let presets: [Float] = [0.8, 0.9, 1, 1.1, 1.25, 1.5]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speed").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(speedLabel(speed))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(Self.presets, id: \.self) { preset in
                    let isOn = abs(preset - speed) < 0.001
                    Button { onSpeed(preset) } label: {
                        Text(speedLabel(preset))
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .background(Capsule().fill(isOn ? AnyShapeStyle(.tint.opacity(0.22))
                                                            : AnyShapeStyle(.primary.opacity(0.06))))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Slider(value: Binding(get: { Double(speed) },
                                  // Snapped to twentieths, so the label reads 1.15× rather than 1.1500001×.
                                  set: { onSpeed(Float(($0 * 20).rounded() / 20)) }),
                   in: 0.5...2)
                .controlSize(.small)
            Picker("", selection: Binding(get: { keepsPitch }, set: onKeepsPitch)) {
                Text("Keep Pitch").tag(true)
                Text("Vinyl").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            // Both laid out, one shown: the panel keeps the taller caption's height as the mode flips.
            ZStack(alignment: .topLeading) {
                caption("Tempo changes, the key stays where it is.", shown: keepsPitch)
                caption("Pitch follows the speed, like sped up and slowed edits.", shown: !keepsPitch)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func caption(_ text: String, shown: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(shown ? 1 : 0)
    }
}

/// The same choices as menu items, for the Controls menu and the pill's own context menu.
struct SpeedMenu: View {
    let player: PlayerEngine

    var body: some View {
        Menu("Playback Speed") {
            // Command-brackets are Back and Forward, and Command-0 brings the window back.
            Button("Faster") { player.stepSpeed(faster: true) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(player.speed >= PlayerEngine.speedSteps.last ?? 2)
            Button("Slower") { player.stepSpeed(faster: false) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(player.speed <= PlayerEngine.speedSteps.first ?? 0.5)
            Button("Normal Speed") { player.speed = 1 }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(player.speed == 1)
            Divider()
            Toggle("Keep Pitch", isOn: Binding(get: { player.keepsPitch }, set: { player.keepsPitch = $0 }))
        }
    }
}

func speedLabel(_ speed: Float) -> String {
    String(format: "%g×", speed)
}

#if DEBUG
#Preview("Speed control") {
    HStack(alignment: .top, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
            SpeedBadge(speed: 1, keepsPitch: true, isRevealed: false) {}
            SpeedBadge(speed: 1, keepsPitch: true, isRevealed: true) {}
            SpeedBadge(speed: 1.25, keepsPitch: true, isRevealed: false) {}
            SpeedBadge(speed: 0.85, keepsPitch: false, isRevealed: false) {}
        }
        SpeedPanel(speed: 1.25, keepsPitch: true, onSpeed: { _ in }, onKeepsPitch: { _ in })
        SpeedPanel(speed: 0.85, keepsPitch: false, onSpeed: { _ in }, onKeepsPitch: { _ in })
    }
    .padding(24)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}

#Preview("Speed in the pill") {
    let json = """
    {"id":1,"title":"Midnight City","duration":243000,"permalink_url":"x","artwork_url":null,\
    "user":{"id":100,"username":"M83"},"media":{"transcodings":[]},"track_authorization":"",\
    "publisher_metadata":{"album_title":"Hurry Up, We're Dreaming"}}
    """
    let track = try! JSONDecoder().decode(SCTrack.self, from: Data(json.utf8))
    // At rest, under the pointer, then off 1× in each pitch mode.
    let states: [(Float, Bool, Bool)] = [(1, true, false), (1, true, true), (1.25, true, false), (0.85, false, false)]
    return VStack(spacing: 14) {
        ForEach(states.indices, id: \.self) { index in
            let (speed, keepsPitch, hover) = states[index]
            PlayerPillContent(track: track, isPlaying: true, currentTime: 78, duration: 243,
                              canPrevious: true, canNext: true, volume: .constant(0.7), isLiked: true,
                              onToggle: {}, onSeek: { _ in }, isQueueVisible: .constant(false),
                              speed: speed, keepsPitch: keepsPitch, forceHover: hover)
        }
    }
    .frame(width: 780)
    .padding(24)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}
#endif
